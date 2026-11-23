#!/usr/bin/env python3
"""Reconcile durable Manul Team workflows with child task-source lifecycle rows.

All state transitions are transactional in the existing Manul SQLite database.
This helper is called by daemon workers; it does not contact external trackers.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

TERMINAL = {"completed", "failed", "skipped", "cancelled"}
SUPPORTED_PROVIDERS = {"github_issues", "todo_local_mcp", "todo_remote_mcp"}


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def connect(path: str) -> sqlite3.Connection:
    db = sqlite3.connect(path, timeout=10, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout=10000")
    return db


def workflow_tables_exist(db: sqlite3.Connection) -> bool:
    row = db.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='workflow_instances'"
    ).fetchone()
    return row is not None


def load_items(state: dict[str, Any]) -> list[dict[str, Any]]:
    data = state.get("data")
    if not isinstance(data, dict):
        raise ValueError("Team workflow checkpoint data must be an object")
    items = data.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("Team workflow must contain at least one work item before waiting")
    result = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"Team work item {index} must be an object")
        item_status = item.get("status", "planned")
        if item_status in TERMINAL and not item.get("trackerRefs"):
            item["status"] = item_status
            result.append(item)
            continue
        refs = item.get("trackerRefs")
        if not isinstance(refs, list) or not refs:
            raise ValueError(f"Team work item {item.get('id', index)!r} has no trackerRefs")
        for ref in refs:
            if not isinstance(ref, dict):
                raise ValueError(f"Team work item {item.get('id', index)!r} has an invalid trackerRef")
            provider = ref.get("provider")
            source_id = ref.get("sourceId")
            if provider not in SUPPORTED_PROVIDERS or not isinstance(source_id, str) or not source_id.strip():
                raise ValueError(
                    f"Team work item {item.get('id', index)!r} has an unsupported or incomplete trackerRef"
                )
            if provider == "github_issues" and not re.fullmatch(
                r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*", source_id
            ):
                raise ValueError(f"Invalid GitHub task source ID in Team item {item.get('id', index)!r}")
            if provider in {"todo_local_mcp", "todo_remote_mcp"} and not re.fullmatch(
                r"[1-9][0-9]*(?:@[0-9a-f]{16})?", source_id
            ):
                raise ValueError(f"Invalid Todo task source ID in Team item {item.get('id', index)!r}")
        result.append(item)
    return result


def park(args: argparse.Namespace) -> int:
    db = connect(args.db)
    try:
        if not workflow_tables_exist(db):
            raise ValueError("Team workflow checkpoint tables are not initialized")
        db.execute("BEGIN IMMEDIATE")
        workflow = db.execute(
            """SELECT workflowId,workflowType,repository,sourceTaskId,conversationId,
                      phase,status,stateJson
               FROM workflow_instances
               WHERE repository=? AND conversationId=? AND workflowType='team'
               ORDER BY updatedAt DESC LIMIT 1""",
            (args.repo, args.conversation_id),
        ).fetchone()
        if workflow is None:
            raise ValueError("No durable Team workflow checkpoint exists for this task")
        if workflow["sourceTaskId"] != args.task_id:
            raise ValueError("Team checkpoint is not owned by the current parent task")
        state = json.loads(workflow["stateJson"])
        if state.get("status") != "waiting_children":
            raise ValueError("Team checkpoint must use status=waiting_children before parking")
        items = load_items(state)
        parent = db.execute(
            "SELECT action,status,claimToken FROM processed_comments WHERE commentId=?",
            (args.task_id,),
        ).fetchone()
        if parent is None or parent["action"] != "TEAM":
            raise ValueError("Parent task is missing or is not a TEAM task")
        if parent["status"] != "running" or parent["claimToken"] != args.claim_token:
            raise ValueError("Current task claim no longer owns the parent TEAM task")
        changed = db.execute(
            """UPDATE processed_comments
               SET status='waiting_children',processedAt=?,heartbeatAt=NULL,
                   leaseExpiresAt=NULL,workerPid=NULL,claimToken=NULL,
                   nextAttemptAt=NULL,session_id=NULL,agentStartedAt=NULL
               WHERE commentId=? AND status='running' AND claimToken=?""",
            (now(), args.task_id, args.claim_token),
        ).rowcount
        if changed != 1:
            raise ValueError("Could not atomically park the parent TEAM task")
        db.execute("COMMIT")
        print(json.dumps({
            "parked": True,
            "workflowId": workflow["workflowId"],
            "taskId": args.task_id,
            "items": len(items),
        }))
        return 0
    except (sqlite3.Error, OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        if db.in_transaction:
            db.execute("ROLLBACK")
        print(json.dumps({"parked": False, "error": str(exc)}), file=sys.stderr)
        return 2
    finally:
        db.close()


def task_execution(db: sqlite3.Connection, provider: str, source_id: str) -> dict[str, Any]:
    if provider in {"todo_local_mcp", "todo_remote_mcp"} and source_id.isdecimal():
        # Todo's task-source adapter appends a structural fingerprint to its
        # source ID. The MCP create API returns the numeric root ID, not that
        # Manul-specific fingerprint; resolve the latest polled version safely.
        row = db.execute(
            """SELECT commentId,repository,issueNumber,status,attempts,prNumber,prUrl,taskSourceUrl,taskSourceId
               FROM processed_comments
               WHERE taskSourceType=? AND (taskSourceId=? OR taskSourceId LIKE ?)
               ORDER BY createdAt DESC, rowid DESC LIMIT 1""",
            (provider, source_id, source_id + "@%"),
        ).fetchone()
    else:
        row = db.execute(
            """SELECT commentId,repository,issueNumber,status,attempts,prNumber,prUrl,taskSourceUrl,taskSourceId
               FROM processed_comments
               WHERE taskSourceType=? AND taskSourceId=?
               ORDER BY createdAt DESC, rowid DESC LIMIT 1""",
            (provider, source_id),
        ).fetchone()
    if row is None:
        return {"status": "pending"}
    status = row["status"]
    if status not in {"completed", "failed", "stale", "blocked_user", "queued", "running", "waiting_children", "skipped", "cancelled"}:
        normalized = "pending"
    elif status == "waiting_children":
        normalized = "waiting"
    elif status in {"skipped", "cancelled"}:
        normalized = status
    elif status == "stale":
        normalized = "failed"
    else:
        normalized = status
    result: dict[str, Any] = {
        "status": normalized,
        "taskId": row["commentId"],
        "sourceId": row["taskSourceId"],
        "repository": row["repository"],
        "issueNumber": row["issueNumber"],
        "attempts": row["attempts"],
    }
    if row["prNumber"] is not None:
        result["prNumber"] = row["prNumber"]
    if row["prUrl"]:
        result["prUrl"] = row["prUrl"]
    if row["taskSourceUrl"]:
        result["sourceUrl"] = row["taskSourceUrl"]
    return result


def add_event(db: sqlite3.Connection, workflow: sqlite3.Row, state: dict[str, Any],
              parent_task_id: str, phase: str) -> None:
    canonical = json.dumps(state, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    event_key = hashlib.sha256(
        f"{workflow['workflowId']}|{parent_task_id}|{canonical}".encode()
    ).hexdigest()
    timestamp = now()
    inserted = db.execute(
        """INSERT OR IGNORE INTO workflow_events
           (workflowId,eventKey,workflowType,repository,taskId,conversationId,
            phase,status,payloadJson,createdAt)
           VALUES(?,?,?,?,?,?,?,?,?,?)""",
        (
            workflow["workflowId"], event_key, "team", workflow["repository"],
            parent_task_id, workflow["conversationId"], phase,
            state["status"], canonical, timestamp,
        ),
    ).rowcount
    if inserted:
        db.execute(
            """UPDATE workflow_instances
               SET phase=?,status=?,stateJson=?,version=version+1,updatedAt=?
               WHERE workflowId=? AND workflowType='team'""",
            (phase, state["status"], canonical, timestamp, workflow["workflowId"]),
        )


def reconcile(args: argparse.Namespace) -> int:
    db = connect(args.db)
    resumed: list[str] = []
    waiting = 0
    try:
        if not workflow_tables_exist(db):
            print(json.dumps({"resumed": [], "waiting": 0}))
            return 0
        db.execute("BEGIN IMMEDIATE")
        workflows = db.execute(
            """SELECT workflowId,workflowType,repository,sourceTaskId,conversationId,
                      phase,status,stateJson
               FROM workflow_instances
               WHERE workflowType='team' AND status='waiting_children'
               ORDER BY updatedAt,workflowId"""
        ).fetchall()
        for workflow in workflows:
            parent_task_id = workflow["sourceTaskId"]
            if not parent_task_id:
                continue
            parent = db.execute(
                "SELECT status,action FROM processed_comments WHERE commentId=?",
                (parent_task_id,),
            ).fetchone()
            if parent is None or parent["action"] != "TEAM" or parent["status"] != "waiting_children":
                continue
            try:
                state = json.loads(workflow["stateJson"])
                items = load_items(state)
            except (json.JSONDecodeError, ValueError, KeyError) as exc:
                # One corrupt workflow must not prevent unrelated Team parents
                # from being reconciled by the same worker cycle.
                waiting += 1
                print(
                    f"team-coordinator: skipping invalid workflow {workflow['workflowId']}: {exc}",
                    file=sys.stderr,
                )
                continue

            all_terminal = True
            new_events: list[dict[str, Any]] = []

            for index, item in enumerate(items):
                tracker_refs = item.get("trackerRefs", [])
                execution_snapshot: list[dict[str, Any]] = []

                if item.get("status") in TERMINAL and not tracker_refs:
                    item_status = item["status"]
                else:
                    executions = []
                    for ref in tracker_refs:
                        execution = task_execution(db, ref["provider"], ref["sourceId"])
                        ref["execution"] = execution
                        executions.append(execution["status"])
                        execution_snapshot.append({
                            "provider": ref["provider"],
                            "sourceId": ref["sourceId"],
                            "execution": execution,
                        })

                    if all(status == "completed" for status in executions):
                        item_status = "completed"
                    elif any(status == "failed" for status in executions) and all(
                        status in TERMINAL for status in executions
                    ):
                        item_status = "failed"
                    elif any(status == "blocked_user" for status in executions):
                        item_status = "waiting_user"
                    elif all(status in TERMINAL for status in executions):
                        item_status = "skipped" if all(
                            status == "skipped" for status in executions
                        ) else "failed"
                    else:
                        item_status = "running" if any(
                            status in {"queued", "running", "waiting"} for status in executions
                        ) else "planned"

                item["status"] = item_status
                if item_status not in TERMINAL:
                    all_terminal = False
                    continue

                # Each logical work item emits one durable notification when
                # its complete tracker-reference set first becomes terminal.
                # The signature changes if the same task is retried and later
                # reaches a different terminal execution.
                item_id = str(item.get("id", index))
                event_payload = {
                    "itemId": item_id,
                    "status": item_status,
                    "trackerRefs": execution_snapshot,
                }
                event_canonical = json.dumps(
                    event_payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
                )
                event_id = hashlib.sha256(
                    f"{workflow['workflowId']}|{event_canonical}".encode()
                ).hexdigest()
                if item.get("lastDispatchedEventKey") != event_id:
                    item["lastDispatchedEventKey"] = event_id
                    new_events.append({"eventId": event_id, **event_payload})

            state["data"]["items"] = items
            coordinator = state["data"].setdefault("coordinator", {})
            if not isinstance(coordinator, dict):
                raise ValueError("Team workflow coordinator checkpoint must be an object")
            pending_events = coordinator.setdefault("pendingChildEvents", [])
            if not isinstance(pending_events, list):
                raise ValueError("Team pendingChildEvents checkpoint must be an array")

            if new_events:
                known_event_ids = {
                    event.get("eventId") for event in pending_events
                    if isinstance(event, dict)
                }
                for event in new_events:
                    if event["eventId"] not in known_event_ids:
                        pending_events.append(event)
                        known_event_ids.add(event["eventId"])

                # Wake on each newly terminal work item, even while unrelated
                # children remain active. Multiple completions in one poll are
                # batched into a single parent run.
                state["status"] = "active"
                pending_failure = any(
                    isinstance(event, dict) and event.get("status") in {"failed", "cancelled"}
                    for event in pending_events
                )
                phase = "replanning" if pending_failure else "integration"
                state["phase"] = phase
                coordinator["lastWakeAt"] = now()
                coordinator["wakeSequence"] = int(coordinator.get("wakeSequence", 0)) + 1
                coordinator["lastWakeReason"] = (
                    "child_failure" if pending_failure else
                    "all_children_terminal" if all_terminal else
                    "child_progress"
                )
                timestamp = now()
                canonical = json.dumps(
                    state, ensure_ascii=False, sort_keys=True, separators=(",", ":")
                )
                changed = db.execute(
                    """UPDATE processed_comments
                       SET status='queued',processedAt=?,heartbeatAt=NULL,
                           leaseExpiresAt=NULL,workerPid=NULL,claimToken=NULL,
                           nextAttemptAt=NULL,session_id=NULL,agentStartedAt=NULL
                       WHERE commentId=? AND status='waiting_children' AND action='TEAM'""",
                    (timestamp, parent_task_id),
                ).rowcount
                if changed != 1:
                    continue

                event_key = hashlib.sha256(
                    f"{workflow['workflowId']}|{parent_task_id}|{canonical}".encode()
                ).hexdigest()
                db.execute(
                    """INSERT OR IGNORE INTO workflow_events
                       (workflowId,eventKey,workflowType,repository,taskId,conversationId,
                        phase,status,payloadJson,createdAt)
                       VALUES(?,?,?,?,?,?,?,?,?,?)""",
                    (
                        workflow["workflowId"], event_key, "team", workflow["repository"],
                        parent_task_id, workflow["conversationId"], phase, "active",
                        canonical, timestamp,
                    ),
                )
                updated = db.execute(
                    """UPDATE workflow_instances
                       SET phase=?,status='active',stateJson=?,version=version+1,updatedAt=?
                       WHERE workflowId=? AND workflowType='team' AND status='waiting_children'""",
                    (phase, canonical, timestamp, workflow["workflowId"]),
                ).rowcount
                if updated != 1:
                    raise ValueError(
                        f"Team workflow {workflow['workflowId']} changed during parent wake"
                    )
                resumed.append(parent_task_id)
                continue

            if not all_terminal:
                # Persist partial child progress even without a new terminal
                # event. The event key makes unchanged polling idempotent.
                state["status"] = "waiting_children"
                state["phase"] = "waiting_children"
                add_event(db, workflow, state, parent_task_id, "waiting_children")
                waiting += 1

        db.execute("COMMIT")
        print(json.dumps({"resumed": resumed, "waiting": waiting}, ensure_ascii=False))
        return 0
    except (sqlite3.Error, OSError, UnicodeError, json.JSONDecodeError, ValueError, KeyError) as exc:
        if db.in_transaction:
            db.execute("ROLLBACK")
        print(json.dumps({"resumed": [], "waiting": waiting, "error": str(exc)}), file=sys.stderr)
        return 2
    finally:
        db.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    park_parser = sub.add_parser("park")
    park_parser.add_argument("--repo", required=True)
    park_parser.add_argument("--conversation-id", required=True)
    park_parser.add_argument("--task-id", required=True)
    park_parser.add_argument("--claim-token", required=True)
    park_parser.set_defaults(func=park)
    reconcile_parser = sub.add_parser("reconcile")
    reconcile_parser.set_defaults(func=reconcile)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
