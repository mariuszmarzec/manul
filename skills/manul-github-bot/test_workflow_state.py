import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "workflow_state", Path(__file__).with_name("workflow-state.py")
)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class WorkflowStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db = module.connect(str(Path(self.temp.name) / "manul.db"))
        self.base = {
            "workflowId": "team:owner/repo:conversation-1",
            "workflowType": "team",
            "repository": "owner/repo",
            "phase": "dispatching",
            "status": "waiting_children",
            "data": {
                "items": [{
                    "id": "work-a",
                    "status": "completed",
                    "lastDispatchedEventKey": "event-key-a",
                    "trackerRefs": [{
                        "provider": "github_issues",
                        "sourceId": "owner/repo#11"
                    }],
                }],
                "coordinator": {
                    "pendingChildEvents": [{
                        "eventId": "event-a",
                        "itemId": "work-a",
                        "status": "completed",
                    }],
                    "wakeSequence": 3,
                    "lastWakeReason": "child_progress",
                },
            },
        }
        self.persist(self.base)

    def tearDown(self):
        self.db.close()
        self.temp.cleanup()

    def persist(self, raw):
        event = module.validate(raw, "owner/repo")
        return module.persist(
            self.db, event, "owner/repo", "parent-task", "conversation-1"
        )

    def stored_state(self):
        row = self.db.execute(
            "SELECT stateJson FROM workflow_instances WHERE workflowId=?",
            (self.base["workflowId"],),
        ).fetchone()
        return json.loads(row["stateJson"])

    def test_checkpoint_omission_preserves_pending_events_and_dispatch_keys(self):
        checkpoint = {
            **self.base,
            "phase": "waiting_children",
            "status": "waiting_children",
            "data": {
                "items": [{
                    "id": "work-a",
                    "status": "completed",
                    "trackerRefs": [{
                        "provider": "github_issues",
                        "sourceId": "owner/repo#11"
                    }],
                }],
            },
        }
        self.assertTrue(self.persist(checkpoint))
        stored = self.stored_state()
        self.assertEqual(
            stored["data"]["coordinator"]["pendingChildEvents"][0]["eventId"],
            "event-a",
        )
        self.assertEqual(stored["data"]["coordinator"]["wakeSequence"], 3)
        self.assertEqual(
            stored["data"]["items"][0]["lastDispatchedEventKey"],
            "event-key-a",
        )

    def test_parent_can_acknowledge_pending_events_without_losing_deduplication(self):
        checkpoint = {
            **self.base,
            "phase": "waiting_children",
            "status": "waiting_children",
            "data": {
                "items": [{
                    "id": "work-a",
                    "status": "completed",
                    "trackerRefs": [{
                        "provider": "github_issues",
                        "sourceId": "owner/repo#11"
                    }],
                }],
                "coordinator": {"pendingChildEvents": []},
            },
        }
        self.assertTrue(self.persist(checkpoint))
        stored = self.stored_state()
        self.assertEqual(stored["data"]["coordinator"]["pendingChildEvents"], [])
        self.assertEqual(stored["data"]["coordinator"]["wakeSequence"], 3)
        self.assertEqual(
            stored["data"]["items"][0]["lastDispatchedEventKey"],
            "event-key-a",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
