import importlib.util
import io
from contextlib import redirect_stderr, redirect_stdout
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("team_coordinator", Path(__file__).with_name("team-coordinator.py"))
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class TeamCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db_path = str(Path(self.temp.name) / "manul.db")
        self.db = sqlite3.connect(self.db_path)
        self.db.executescript("""
          CREATE TABLE workflow_instances(
            workflowId TEXT PRIMARY KEY, workflowType TEXT, repository TEXT,
            sourceTaskId TEXT, conversationId TEXT, phase TEXT, status TEXT,
            stateJson TEXT, version INTEGER, createdAt TEXT, updatedAt TEXT
          );
          CREATE TABLE workflow_events(
            id INTEGER PRIMARY KEY AUTOINCREMENT, workflowId TEXT, eventKey TEXT UNIQUE,
            workflowType TEXT, repository TEXT, taskId TEXT, conversationId TEXT,
            phase TEXT, status TEXT, payloadJson TEXT, createdAt TEXT
          );
          CREATE TABLE processed_comments(
            commentId TEXT PRIMARY KEY, repository TEXT, issueNumber INTEGER,
            status TEXT, attempts INTEGER, prNumber INTEGER, prUrl TEXT, taskSourceUrl TEXT,
            taskSourceType TEXT, taskSourceId TEXT, action TEXT, claimToken TEXT,
            createdAt TEXT, processedAt TEXT, heartbeatAt TEXT, leaseExpiresAt TEXT, workerPid INTEGER,
            nextAttemptAt TEXT, session_id TEXT, agentStartedAt TEXT
          );
        """)
        self.db.commit()
        self.workflow_id = "team:owner/repo:conversation-1"
        self.parent_id = "source:github_issues:owner/repo#10"
        self.child_id = "source:github_issues:owner/repo#11"
        self.state = {
            "workflowId": self.workflow_id,
            "workflowType": "team",
            "repository": "owner/repo",
            "phase": "dispatching",
            "status": "waiting_children",
            "data": {
                "items": [{
                    "id": "work-1", "status": "created",
                    "trackerRefs": [{"provider": "github_issues", "sourceId": "owner/repo#11"}]
                }]
            }
        }
        now = module.now()
        self.db.execute(
            """INSERT INTO workflow_instances VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
            (self.workflow_id, "team", "owner/repo", self.parent_id, "conversation-1",
             "dispatching", "waiting_children", json.dumps(self.state), 1, now, now)
        )
        self.db.execute(
            """INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,
                 taskSourceType,taskSourceId,action,claimToken)
               VALUES(?,?,?,?,?,?,?,?,?)""",
            (self.parent_id, "owner/repo", 10, "running", 1,
             "github_issues", "owner/repo#10", "TEAM", "claim-1")
        )
        self.db.commit()

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def run_park(self, token="claim-1"):
        import argparse
        return module.park(argparse.Namespace(
            db=self.db_path, repo="owner/repo", conversation_id="conversation-1",
            task_id=self.parent_id, claim_token=token
        ))

    def run_reconcile(self):
        import argparse
        return module.reconcile(argparse.Namespace(db=self.db_path))

    def set_waiting_items(self, items):
        state = json.loads(json.dumps(self.state))
        state["status"] = "waiting_children"
        state["phase"] = "waiting_children"
        state["data"]["items"] = items
        self.db.execute(
            "UPDATE workflow_instances SET stateJson=?,status='waiting_children',phase='waiting_children' WHERE workflowId=?",
            (json.dumps(state), self.workflow_id)
        )
        self.db.execute(
            "UPDATE processed_comments SET status='waiting_children',claimToken=NULL,"
            "attempts=CASE WHEN attempts>0 THEN attempts-1 ELSE 0 END WHERE commentId=?",
            (self.parent_id,)
        )
        self.db.commit()

    def insert_child(self, number, status, attempts=1, pr_number=None, pr_url=None):
        comment_id = f"source:github_issues:owner/repo#{number}"
        source_id = f"owner/repo#{number}"
        self.db.execute(
            """INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,
                 prNumber,prUrl,taskSourceType,taskSourceId,action)
               VALUES(?,?,?,?,?,?,?,?,?,?)""",
            (comment_id, "owner/repo", number, status, attempts, pr_number, pr_url,
             "github_issues", source_id, "IMPLEMENT")
        )

    def test_park_transitions_only_current_claim_to_waiting_children(self):
        self.assertEqual(self.run_park(), 0)
        row = self.db.execute(
            "SELECT status,claimToken,heartbeatAt,workerPid,attempts FROM processed_comments WHERE commentId=?",
            (self.parent_id,)
        ).fetchone()
        self.assertEqual(row, ("waiting_children", None, None, None, 0))

    def test_park_rejects_stale_claim(self):
        self.assertEqual(self.run_park("old-claim"), 2)
        status = self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0]
        self.assertEqual(status, "running")

    def test_park_requires_tracker_refs(self):
        invalid = dict(self.state)
        invalid["data"] = {"items": [{"id": "work-1", "status": "planned", "trackerRefs": []}]}
        self.db.execute("UPDATE workflow_instances SET stateJson=?", (json.dumps(invalid),))
        self.db.commit()
        self.assertEqual(self.run_park(), 2)

    def test_todo_numeric_id_resolves_latest_fingerprinted_source(self):
        self.db.execute(
            """INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,
                 prNumber,prUrl,taskSourceType,taskSourceId,action)
               VALUES(?,?,?,?,?,?,?,?,?,?)""",
            ("todo-child", "owner/repo", 991, "queued", 0, None, None,
             "todo_local_mcp", "991@0123456789abcdef", "IMPLEMENT")
        )
        self.db.commit()
        self.db.row_factory = sqlite3.Row
        execution = module.task_execution(self.db, "todo_local_mcp", "991")
        self.assertEqual(execution["status"], "queued")
        self.assertEqual(execution["sourceId"], "991@0123456789abcdef")

    def test_reconcile_waits_while_child_is_queued(self):
        self.db.execute(
            """INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,
                 taskSourceType,taskSourceId,action)
               VALUES(?,?,?,?,?,?,?,?)""",
            (self.child_id, "owner/repo", 11, "queued", 0, "github_issues", "owner/repo#11", "IMPLEMENT")
        )
        self.db.execute(
            "UPDATE processed_comments SET status='waiting_children',claimToken=NULL WHERE commentId=?",
            (self.parent_id,)
        )
        self.db.commit()
        self.assertEqual(self.run_reconcile(), 0)
        row = self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0]
        self.assertEqual(row, "waiting_children")
        stored = self.db.execute(
            "SELECT status,phase,stateJson FROM workflow_instances WHERE workflowId=?",
            (self.workflow_id,)
        ).fetchone()
        self.assertEqual(stored[0:2], ("waiting_children", "waiting_children"))
        item = json.loads(stored[2])["data"]["items"][0]
        self.assertEqual(item["status"], "running")
        self.assertEqual(item["trackerRefs"][0]["execution"]["status"], "queued")
        self.assertEqual(self.db.execute(
            "SELECT COUNT(*) FROM workflow_events WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0], 1)
        # Repeated unchanged reconciliation must be idempotent.
        self.assertEqual(self.run_reconcile(), 0)
        self.assertEqual(self.db.execute(
            "SELECT COUNT(*) FROM workflow_events WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0], 1)

    def test_reconcile_wakes_parent_once_after_child_completion(self):
        self.db.execute(
            """INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,
                 prNumber,prUrl,taskSourceType,taskSourceId,action)
               VALUES(?,?,?,?,?,?,?,?,?,?)""",
            (self.child_id, "owner/repo", 11, "completed", 1, 21,
             "https://github.com/owner/repo/pull/21", "github_issues", "owner/repo#11", "IMPLEMENT")
        )
        self.db.execute(
            "UPDATE processed_comments SET status='waiting_children',claimToken=NULL WHERE commentId=?",
            (self.parent_id,)
        )
        self.db.commit()
        self.assertEqual(self.run_reconcile(), 0)
        row = self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0]
        self.assertEqual(row, "queued")
        stored = self.db.execute(
            "SELECT status,phase,stateJson FROM workflow_instances WHERE workflowId=?",
            (self.workflow_id,)
        ).fetchone()
        self.assertEqual(stored[0:2], ("active", "integration"))
        item = json.loads(stored[2])["data"]["items"][0]
        self.assertEqual(item["status"], "completed")
        self.assertEqual(item["trackerRefs"][0]["execution"]["prNumber"], 21)
        self.assertEqual(self.run_reconcile(), 0)
        self.assertEqual(self.db.execute(
            "SELECT COUNT(*) FROM workflow_events WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0], 1)

    def test_child_failure_wakes_parent_for_replanning(self):
        self.db.execute(
            """INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,
                 taskSourceType,taskSourceId,action)
               VALUES(?,?,?,?,?,?,?,?)""",
            (self.child_id, "owner/repo", 11, "failed", 3, "github_issues", "owner/repo#11", "IMPLEMENT")
        )
        self.db.execute(
            "UPDATE processed_comments SET status='waiting_children',claimToken=NULL WHERE commentId=?",
            (self.parent_id,)
        )
        self.db.commit()
        self.assertEqual(self.run_reconcile(), 0)
        phase = self.db.execute(
            "SELECT phase FROM workflow_instances WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0]
        self.assertEqual(phase, "replanning")

    def test_skipped_child_is_terminal_and_does_not_stall_parent(self):
        self.db.execute(
            """INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,
                 taskSourceType,taskSourceId,action)
               VALUES(?,?,?,?,?,?,?,?)""",
            (self.child_id, "owner/repo", 11, "skipped", 0, "github_issues", "owner/repo#11", "IMPLEMENT")
        )
        self.db.execute(
            "UPDATE processed_comments SET status='waiting_children',claimToken=NULL WHERE commentId=?",
            (self.parent_id,)
        )
        self.db.commit()
        self.assertEqual(self.run_reconcile(), 0)
        parent_status = self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0]
        stored = self.db.execute(
            "SELECT phase,stateJson FROM workflow_instances WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()
        item = json.loads(stored[1])["data"]["items"][0]
        self.assertEqual(parent_status, "queued")
        self.assertEqual(stored[0], "integration")
        self.assertEqual(item["status"], "skipped")
        self.assertEqual(item["trackerRefs"][0]["execution"]["status"], "skipped")

    def test_cancelled_child_wakes_parent_for_replanning(self):
        self.db.execute(
            """INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,
                 taskSourceType,taskSourceId,action)
               VALUES(?,?,?,?,?,?,?,?)""",
            (self.child_id, "owner/repo", 11, "cancelled", 1, "github_issues", "owner/repo#11", "IMPLEMENT")
        )
        self.db.execute(
            "UPDATE processed_comments SET status='waiting_children',claimToken=NULL WHERE commentId=?",
            (self.parent_id,)
        )
        self.db.commit()
        self.assertEqual(self.run_reconcile(), 0)
        phase = self.db.execute(
            "SELECT phase FROM workflow_instances WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0]
        self.assertEqual(phase, "replanning")

    def test_failed_local_item_without_tracker_refs_replans(self):
        failed_state = dict(self.state)
        failed_state["data"] = {"items": [{"id": "local-failure", "status": "failed"}]}
        self.db.execute(
            "UPDATE workflow_instances SET stateJson=?,status='waiting_children' WHERE workflowId=?",
            (json.dumps(failed_state), self.workflow_id)
        )
        self.db.execute(
            "UPDATE processed_comments SET status='waiting_children',claimToken=NULL WHERE commentId=?",
            (self.parent_id,)
        )
        self.db.commit()
        self.assertEqual(self.run_reconcile(), 0)
        phase = self.db.execute(
            "SELECT phase FROM workflow_instances WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0]
        self.assertEqual(phase, "replanning")

    def test_reconcile_wakes_parent_after_one_child_completes_and_deduplicates(self):
        self.set_waiting_items([
            {"id": "work-a", "status": "created",
             "trackerRefs": [{"provider": "github_issues", "sourceId": "owner/repo#11"}]},
            {"id": "work-b", "status": "created",
             "trackerRefs": [{"provider": "github_issues", "sourceId": "owner/repo#12"}]},
        ])
        self.insert_child(11, "completed", pr_number=21,
                          pr_url="https://github.com/owner/repo/pull/21")
        self.insert_child(12, "queued", attempts=0)
        self.db.commit()

        self.assertEqual(self.run_reconcile(), 0)
        parent_status = self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0]
        self.assertEqual(parent_status, "queued")

        stored = self.db.execute(
            "SELECT phase,stateJson FROM workflow_instances WHERE workflowId=?",
            (self.workflow_id,)
        ).fetchone()
        self.assertEqual(stored[0], "integration")
        state = json.loads(stored[1])
        items = {item["id"]: item for item in state["data"]["items"]}
        self.assertEqual(items["work-a"]["status"], "completed")
        self.assertEqual(items["work-b"]["status"], "running")
        pending = state["data"]["coordinator"]["pendingChildEvents"]
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["itemId"], "work-a")
        self.assertEqual(pending[0]["status"], "completed")
        self.assertEqual(pending[0]["trackerRefs"][0]["execution"]["prNumber"], 21)

        # A queued parent is not woken repeatedly by the same child snapshot.
        self.assertEqual(self.run_reconcile(), 0)
        self.assertEqual(self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0], "queued")

        # Simulate the parent consuming A's event and parking again while B runs.
        state["status"] = "waiting_children"
        state["phase"] = "dispatching"
        state["data"]["coordinator"]["pendingChildEvents"] = []
        self.db.execute(
            "UPDATE workflow_instances SET stateJson=?,status='waiting_children',phase='dispatching' WHERE workflowId=?",
            (json.dumps(state), self.workflow_id)
        )
        self.db.execute(
            "UPDATE processed_comments SET status='running',claimToken='claim-2',attempts=attempts+1 WHERE commentId=?",
            (self.parent_id,)
        )
        self.db.commit()
        self.assertEqual(self.run_park("claim-2"), 0)
        self.assertEqual(self.db.execute(
            "SELECT attempts FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0], 0)

        # The same completed A result is already delivered; B is still active.
        self.assertEqual(self.run_reconcile(), 0)
        self.assertEqual(self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0], "waiting_children")

        # B's later completion creates a second, distinct parent wake.
        self.db.execute(
            "UPDATE processed_comments SET status='completed',attempts=1,prNumber=22,"
            "prUrl='https://github.com/owner/repo/pull/22' "
            "WHERE taskSourceType='github_issues' AND taskSourceId='owner/repo#12'"
        )
        self.db.commit()
        self.assertEqual(self.run_reconcile(), 0)
        self.assertEqual(self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0], "queued")
        final_state = json.loads(self.db.execute(
            "SELECT stateJson FROM workflow_instances WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0])
        pending = final_state["data"]["coordinator"]["pendingChildEvents"]
        self.assertEqual([event["itemId"] for event in pending], ["work-b"])

    def test_reconcile_batches_child_completions_seen_in_same_cycle(self):
        self.set_waiting_items([
            {"id": "work-a", "status": "created",
             "trackerRefs": [{"provider": "github_issues", "sourceId": "owner/repo#11"}]},
            {"id": "work-b", "status": "created",
             "trackerRefs": [{"provider": "github_issues", "sourceId": "owner/repo#12"}]},
        ])
        self.insert_child(11, "completed", pr_number=21)
        self.insert_child(12, "completed", pr_number=22)
        self.db.commit()

        self.assertEqual(self.run_reconcile(), 0)
        self.assertEqual(self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0], "queued")
        state = json.loads(self.db.execute(
            "SELECT stateJson FROM workflow_instances WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0])
        pending = state["data"]["coordinator"]["pendingChildEvents"]
        self.assertEqual({event["itemId"] for event in pending}, {"work-a", "work-b"})
        self.assertEqual(state["data"]["coordinator"]["wakeSequence"], 1)

    def test_reconcile_wakes_for_failure_while_another_child_is_running(self):
        self.set_waiting_items([
            {"id": "work-a", "status": "created",
             "trackerRefs": [{"provider": "github_issues", "sourceId": "owner/repo#11"}]},
            {"id": "work-b", "status": "created",
             "trackerRefs": [{"provider": "github_issues", "sourceId": "owner/repo#12"}]},
        ])
        self.insert_child(11, "failed", attempts=3)
        self.insert_child(12, "queued", attempts=0)
        self.db.commit()

        self.assertEqual(self.run_reconcile(), 0)
        self.assertEqual(self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0], "queued")
        state = json.loads(self.db.execute(
            "SELECT stateJson FROM workflow_instances WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0])
        self.assertEqual(state["phase"], "replanning")
        items = {item["id"]: item for item in state["data"]["items"]}
        self.assertEqual(items["work-a"]["status"], "failed")
        self.assertEqual(items["work-b"]["status"], "running")
        self.assertEqual(
            [event["status"] for event in state["data"]["coordinator"]["pendingChildEvents"]],
            ["failed"]
        )

    def test_child_completed_before_parent_parks_is_detected_after_park(self):
        self.insert_child(11, "completed", pr_number=21)
        self.db.commit()

        # The child can finish while the parent is still executing its plan.
        self.assertEqual(self.run_park(), 0)
        self.assertEqual(self.run_reconcile(), 0)
        self.assertEqual(self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0], "queued")
        state = json.loads(self.db.execute(
            "SELECT stateJson FROM workflow_instances WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0])
        self.assertEqual(len(state["data"]["coordinator"]["pendingChildEvents"]), 1)

    def test_blocked_child_does_not_wake_parent(self):
        self.db.execute(
            """INSERT INTO processed_comments(commentId,repository,issueNumber,status,attempts,
                 taskSourceType,taskSourceId,action)
               VALUES(?,?,?,?,?,?,?,?)""",
            (self.child_id, "owner/repo", 11, "blocked_user", 1, "github_issues", "owner/repo#11", "IMPLEMENT")
        )
        self.db.execute(
            "UPDATE processed_comments SET status='waiting_children',claimToken=NULL WHERE commentId=?",
            (self.parent_id,)
        )
        self.db.commit()
        self.assertEqual(self.run_reconcile(), 0)
        status = self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0]
        self.assertEqual(status, "waiting_children")


    def configure_completion_guard(self, items, pending=None, finalization=False):
        state = json.loads(json.dumps(self.state))
        state["status"], state["phase"] = "active", "integration"
        state["data"]["items"] = items
        coordinator = {"pendingChildEvents": list(pending or [])}
        if finalization:
            state["status"], state["phase"] = "completed", "completed"
            coordinator["finalization"] = {
                "status": "passed", "qaPassed": True,
                "summary": "All child work integrated and final regression QA passed.",
            }
        state["data"]["coordinator"] = coordinator
        self.db.execute(
            "UPDATE workflow_instances SET stateJson=?,status=?,phase=? WHERE workflowId=?",
            (json.dumps(state), state["status"], state["phase"], self.workflow_id),
        )
        self.db.execute(
            "UPDATE processed_comments SET status='running',claimToken='claim-1',attempts=1 WHERE commentId=?",
            (self.parent_id,),
        )
        self.db.commit()

    def run_completion_guard(self, claim_token="claim-1"):
        import argparse
        output = io.StringIO()
        with redirect_stdout(output):
            rc = module.completion_guard(argparse.Namespace(
                db=self.db_path, repo="owner/repo", conversation_id="conversation-1",
                task_id=self.parent_id, claim_token=claim_token
            ))
        return rc, json.loads(output.getvalue()) if output.getvalue().strip() else {}

    @staticmethod
    def team_item(item_id, *source_ids):
        return {
            "id": item_id, "status": "created",
            "trackerRefs": [
                {"provider": "github_issues", "sourceId": source_id}
                for source_id in source_ids
            ],
        }

    def test_completion_guard_parks_while_any_child_is_active(self):
        self.insert_child(11, "completed", pr_number=21)
        self.insert_child(12, "queued", attempts=0)
        self.configure_completion_guard([
            self.team_item("work-a", "owner/repo#11"),
            self.team_item("work-b", "owner/repo#12"),
        ])
        rc, result = self.run_completion_guard()
        self.assertEqual(rc, 0)
        self.assertEqual(result["action"], "parked")
        self.assertEqual(result["nonTerminalItems"], 1)
        parent = self.db.execute(
            "SELECT status,claimToken,attempts FROM processed_comments WHERE commentId=?",
            (self.parent_id,),
        ).fetchone()
        self.assertEqual(parent, ("waiting_children", None, 0))
        workflow = self.db.execute(
            "SELECT status,phase,stateJson FROM workflow_instances WHERE workflowId=?",
            (self.workflow_id,),
        ).fetchone()
        self.assertEqual(workflow[0:2], ("waiting_children", "waiting_children"))
        stored = json.loads(workflow[2])
        self.assertEqual(
            {item["id"]: item["status"] for item in stored["data"]["items"]},
            {"work-a": "completed", "work-b": "running"},
        )

    def test_completion_guard_requeues_when_child_event_is_pending(self):
        self.insert_child(11, "completed", pr_number=21)
        self.insert_child(12, "queued", attempts=0)
        pending = [{"eventId": "event-a", "itemId": "work-a", "status": "completed"}]
        self.configure_completion_guard([
            self.team_item("work-a", "owner/repo#11"),
            self.team_item("work-b", "owner/repo#12"),
        ], pending=pending)
        rc, result = self.run_completion_guard()
        self.assertEqual(rc, 0)
        self.assertEqual(result["action"], "queued")
        self.assertEqual(self.db.execute(
            "SELECT status FROM processed_comments WHERE commentId=?", (self.parent_id,)
        ).fetchone()[0], "queued")
        stored = json.loads(self.db.execute(
            "SELECT stateJson FROM workflow_instances WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0])
        self.assertEqual(stored["data"]["coordinator"]["pendingChildEvents"][0]["eventId"], "event-a")

    def test_completion_guard_checks_every_tracker_reference(self):
        self.insert_child(11, "completed", pr_number=21)
        self.insert_child(12, "running", attempts=1)
        self.configure_completion_guard([
            self.team_item("work-a", "owner/repo#11", "owner/repo#12"),
        ])
        rc, result = self.run_completion_guard()
        self.assertEqual(rc, 0)
        self.assertEqual(result["action"], "parked")
        stored = json.loads(self.db.execute(
            "SELECT stateJson FROM workflow_instances WHERE workflowId=?", (self.workflow_id,)
        ).fetchone()[0])
        self.assertEqual(stored["data"]["items"][0]["status"], "running")

    def test_completion_guard_blocks_all_terminal_items_with_pending_event(self):
        self.insert_child(11, "completed", pr_number=21)
        self.insert_child(12, "completed", pr_number=22)
        pending = [{"eventId": "event-b", "itemId": "work-b", "status": "completed"}]
        self.configure_completion_guard([
            self.team_item("work-a", "owner/repo#11"),
            self.team_item("work-b", "owner/repo#12"),
        ], pending=pending, finalization=True)
        rc, result = self.run_completion_guard()
        self.assertEqual(rc, 0)
        self.assertEqual(result["action"], "queued")
        self.assertEqual(result["pendingEvents"], 1)

    def test_completion_guard_requires_explicit_final_qa_checkpoint(self):
        self.insert_child(11, "completed", pr_number=21)
        self.configure_completion_guard([self.team_item("work-a", "owner/repo#11")])
        rc, result = self.run_completion_guard()
        self.assertEqual(rc, 0)
        self.assertEqual(result["action"], "queued")
        self.assertFalse(result["finalQaComplete"])

    def test_completion_guard_allows_only_terminal_acknowledged_finalized_workflow(self):
        self.insert_child(11, "completed", pr_number=21)
        self.insert_child(12, "completed", pr_number=22)
        self.configure_completion_guard([
            self.team_item("work-a", "owner/repo#11"),
            self.team_item("work-b", "owner/repo#12"),
        ], finalization=True)
        rc, result = self.run_completion_guard()
        self.assertEqual(rc, 0)
        self.assertEqual(result["action"], "allow")
        self.assertEqual(self.db.execute(
            "SELECT status,claimToken FROM processed_comments WHERE commentId=?",
            (self.parent_id,),
        ).fetchone(), ("running", "claim-1"))

    def test_completion_guard_rejects_stale_claim_without_transition(self):
        self.insert_child(11, "completed", pr_number=21)
        self.configure_completion_guard([self.team_item("work-a", "owner/repo#11")], finalization=True)
        error = io.StringIO()
        with redirect_stderr(error):
            rc, result = self.run_completion_guard(claim_token="stale-claim")
        self.assertEqual(rc, 2)
        self.assertEqual(self.db.execute(
            "SELECT status,claimToken FROM processed_comments WHERE commentId=?",
            (self.parent_id,),
        ).fetchone(), ("running", "claim-1"))

    def test_daemon_checks_team_done_before_generic_completion(self):
        daemon = Path(__file__).with_name("manul-daemon.sh").read_text(encoding="utf-8")
        self.assertLess(daemon.index("completion-guard"), daemon.index('evaluate_task_completion "$REPO"'))
        self.assertIn("grep -qE '^TASK_(DONE|COMPLETED)", daemon)



if __name__ == "__main__":
    unittest.main(verbosity=2)
