import importlib.util
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

    def test_park_transitions_only_current_claim_to_waiting_children(self):
        self.assertEqual(self.run_park(), 0)
        row = self.db.execute(
            "SELECT status,claimToken,heartbeatAt,workerPid FROM processed_comments WHERE commentId=?",
            (self.parent_id,)
        ).fetchone()
        self.assertEqual(row, ("waiting_children", None, None, None))

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


if __name__ == "__main__":
    unittest.main(verbosity=2)
