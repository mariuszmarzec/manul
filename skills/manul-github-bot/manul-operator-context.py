#!/usr/bin/env python3
"""Build a bounded, secret-redacted, read-only snapshot for Manul operator queries."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any

SECRET_PATTERNS = [
    re.compile(r"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s,;]+"),
    re.compile(r"(?i)(\b(?:access_token|refresh_token|token|api[_-]?key|secret|password|passwd|pat|credential)\b\s*[:=]\s*)[\"']?[^\s,;\"'}]+"),
    re.compile(r"(?i)(https?://)[^/@\s]+:[^/@\s]+@"),
    re.compile(r"(?i)(--?(?:token|password|secret|api-key)\s+)[^\s]+"),
]


def redact(value: Any) -> str:
    text = str(value if value is not None else "")
    for name, secret in os.environ.items():
        if secret and re.search(r"(?:TOKEN|SECRET|PASSWORD|PASSWD|API[_-]?KEY|PAT|CREDENTIAL|AUTH)", name, re.I):
            text = text.replace(secret, "[REDACTED]")
    for pattern in SECRET_PATTERNS:
        if pattern.pattern.startswith("(?i)(https?"):
            text = pattern.sub(r"\1[REDACTED]@", text)
        else:
            text = pattern.sub(r"\1[REDACTED]", text)
    return "".join(ch for ch in text if ch in "\n\r\t" or ord(ch) >= 32)


def compact(value: Any, limit: int) -> str:
    return redact(value).strip()[:limit]


def parse_time(value: Any) -> dt.datetime | None:
    if not value:
        return None
    raw = str(value).strip().replace("Z", "+00:00")
    try:
        parsed = dt.datetime.fromisoformat(raw)
    except ValueError:
        try:
            parsed = dt.datetime.strptime(raw, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def task_activity(row: dict[str, Any]) -> dt.datetime | None:
    times = [parse_time(row.get(key)) for key in ("agentStartedAt", "processedAt", "createdAt")]
    return max((item for item in times if item is not None), default=None)


def load_tasks(db_path: Path, now: dt.datetime) -> tuple[list[dict[str, Any]], dict[str, int]]:
    if not db_path.is_file() or db_path.is_symlink() or db_path.stat().st_size == 0:
        raise RuntimeError("Manul SQLite database is missing, empty, or not a regular file")

    uri = db_path.resolve(strict=True).as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=2)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("PRAGMA query_only = ON")
        table = connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='processed_comments'"
        ).fetchone()
        if table is None:
            raise RuntimeError("Manul database has no processed_comments table")
        rows = connection.execute(
            "SELECT * FROM processed_comments ORDER BY rowid DESC LIMIT 300"
        ).fetchall()
    finally:
        connection.close()

    active_statuses = {"queued", "running", "blocked_user"}
    cutoff = now - dt.timedelta(days=7)
    selected: list[tuple[dt.datetime, dict[str, Any]]] = []
    counts: dict[str, int] = {}
    for raw_row in rows:
        row = dict(raw_row)
        status = str(row.get("status") or "unknown")
        counts[status] = counts.get(status, 0) + 1
        activity = task_activity(row)
        if status not in active_statuses and (activity is None or activity < cutoff):
            continue
        source_id = row.get("taskSourceId")
        if source_id:
            source_id = str(source_id).split("@", 1)[0]
        selected.append(
            (
                activity or dt.datetime.min.replace(tzinfo=dt.timezone.utc),
                {
                    "taskId": compact(row.get("commentId"), 180),
                    "repository": compact(row.get("repository"), 180),
                    "issue": row.get("issueNumber"),
                    "status": compact(status, 40),
                    "sourceType": compact(row.get("taskSourceType"), 60) or None,
                    "sourceId": compact(source_id, 120) or None,
                    "agent": compact(row.get("agent"), 80) or None,
                    "attempts": row.get("attempts") or 0,
                    "createdAt": compact(row.get("createdAt"), 80) or None,
                    "agentStartedAt": compact(row.get("agentStartedAt"), 80) or None,
                    "processedAt": compact(row.get("processedAt"), 80) or None,
                    "prompt": compact(row.get("prompt"), 1600),
                    "resultSummary": compact(row.get("resultSummary"), 2400),
                    "context": compact(row.get("context"), 1200),
                },
            )
        )
    selected.sort(key=lambda item: item[0], reverse=True)
    return [item[1] for item in selected[:100]], counts


def read_tail(path: Path, lines: int = 60) -> list[str]:
    if path.is_symlink() or not path.is_file():
        return []
    try:
        if path.stat().st_size > 2 * 1024 * 1024:
            return ["[log omitted: file exceeds 2 MiB limit]"]
        content = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        return [f"[log unreadable: {type(exc).__name__}]"]
    return [compact(line, 900) for line in content[-lines:]]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    parser.add_argument("--logs-dir", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    now = dt.datetime.now(dt.timezone.utc)
    try:
        tasks, counts = load_tasks(Path(args.db), now)
    except Exception as exc:
        print(f"operator context: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    logs_root = Path(args.logs_dir)
    if logs_root.is_symlink() or not logs_root.is_dir():
        logs_root = Path("/__manul_operator_logs_unavailable__")
    logs: dict[str, list[str]] = {}
    for name in ("lifecycle.log", "daemon.log", "poll.log", "watchdog.log"):
        lines = read_tail(logs_root / name)
        if lines:
            logs[name] = lines

    active = [task for task in tasks if task["status"] in {"queued", "running", "blocked_user"}]
    snapshot = {
        "generatedAt": now.isoformat(),
        "scope": "read-only operator snapshot; active tasks plus tasks with activity in the last 7 days",
        "taskCountsInRecent300Rows": counts,
        "activeTaskCountInRecent300Rows": len(active),
        "tasks": tasks,
        "logs": logs,
    }
    encoded = json.dumps(snapshot, ensure_ascii=False, indent=2)
    # Prevent embedded task descriptions/logs from terminating the surrounding
    # Markdown data block when the prompt is handed to an agent.
    encoded = encoded.replace("\u0060", "\\u0060")
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(encoded + "\n", encoding="utf-8")
    os.chmod(output_path, 0o600)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
