#!/usr/bin/env python3
"""Hermetic tests for the Manul monitor registry and poller."""
from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).with_name("manul-monitor.py")
SPEC = importlib.util.spec_from_file_location("manul_monitor", SCRIPT)
assert SPEC and SPEC.loader
monitor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(monitor)


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.manul_config = root / "config.json"
        self.manul_config.write_text(json.dumps({
            "repositories": ["acme/app", "acme/other"],
            "taskSources": [
                {"type": "todo_local_mcp", "enabled": True, "url": "http://127.0.0.1:8765/mcp"}
            ],
        }), encoding="utf-8")
        os.environ.update({
            "MANUL_DIR": str(root / "manul"),
            "MANUL_STATE_DIR": str(root / "manul" / "state"),
            "MANUL_LOCKS_DIR": str(root / "manul" / "state" / "locks"),
            "MANUL_CONFIG": str(self.manul_config),
            "MANUL_MONITORS_DB": str(root / "manul" / "state" / "monitors.db"),
            "MANUL_MONITORS_DIR": str(root / "manul" / "monitors"),
            "MANUL_MONITOR_LOG": str(root / "manul" / "logs" / "monitor.log"),
        })
        self.paths = monitor.paths()
        self.definition = {
            "id": "external-prs",
            "name": "External pull requests",
            "schedule": {"intervalSeconds": 300},
            "source": {"type": "github_pull_requests", "repositories": "configured"},
            "filters": {"excludeSelf": True, "excludeDrafts": True},
            "outputs": ["log"],
        }
        self.definition_file = root / "monitor.json"
        self.definition_file.write_text(json.dumps(self.definition), encoding="utf-8")

    def tearDown(self):
        self.temp.cleanup()
        for key in (
            "MANUL_DIR", "MANUL_STATE_DIR", "MANUL_LOCKS_DIR", "MANUL_CONFIG",
            "MANUL_MONITORS_DB", "MANUL_MONITORS_DIR", "MANUL_MONITOR_LOG",
        ):
            os.environ.pop(key, None)

    def create_monitor(self):
        return monitor.create(Namespace(config=str(self.definition_file)), self.paths)

    def test_validation_rejects_repository_outside_global_allowlist(self):
        bad = dict(self.definition)
        bad["source"] = {"type": "github_pull_requests", "repositories": ["someone/else"]}
        with self.assertRaises(monitor.MonitorError):
            monitor.validate(bad, monitor.load_json(self.manul_config, "test config"))

    def test_validation_requires_enabled_todo_output_provider(self):
        bad = dict(self.definition)
        bad["outputs"] = ["todo_local"]
        manul = monitor.load_json(self.manul_config, "test config")
        manul["taskSources"] = []
        with self.assertRaises(monitor.MonitorError):
            monitor.validate(bad, manul)

    def test_create_pause_resume_update_and_soft_delete(self):
        created = self.create_monitor()
        self.assertEqual(created["id"], "external-prs")
        self.assertEqual(created["status"], "active")
        paused = monitor.set_status(Namespace(monitor_id="external-prs"), self.paths, "paused")
        self.assertEqual(paused["status"], "paused")
        resumed = monitor.set_status(Namespace(monitor_id="external-prs"), self.paths, "active")
        self.assertEqual(resumed["status"], "active")

        self.definition["name"] = "Updated PR monitor"
        self.definition_file.write_text(json.dumps(self.definition), encoding="utf-8")
        updated = monitor.update(Namespace(monitor_id="external-prs", config=str(self.definition_file)), self.paths)
        self.assertEqual(updated["status"], "active")
        self.assertEqual(monitor.show(Namespace(monitor_id="external-prs"), self.paths)["name"], "Updated PR monitor")

        deleted = monitor.delete(Namespace(monitor_id="external-prs"), self.paths)
        self.assertTrue(deleted["workspaceRetained"])
        self.assertEqual(monitor.listing(Namespace(all=True), self.paths)[0]["status"], "deleted")
        self.assertEqual(monitor.listing(Namespace(all=False), self.paths), [])

    def test_new_external_non_draft_pr_is_discovered_once(self):
        self.create_monitor()
        pr_items = [
            {"number": 1, "title": "Own PR", "url": "https://github.com/acme/app/pull/1",
             "author": {"login": "primary"}, "isDraft": False, "createdAt": "2099-01-01T00:00:00Z"},
            {"number": 2, "title": "Draft PR", "url": "https://github.com/acme/app/pull/2",
             "author": {"login": "contributor"}, "isDraft": True, "createdAt": "2099-01-01T00:00:00Z"},
            {"number": 3, "title": "External PR", "url": "https://github.com/acme/app/pull/3",
             "author": {"login": "contributor"}, "isDraft": False, "createdAt": "2099-01-01T00:00:00Z"},
        ]
        def prs_for_repo(repository):
            return pr_items if repository == "acme/app" else []

        with patch.object(monitor, "gh_login", return_value="primary"), patch.object(monitor, "gh_prs", side_effect=prs_for_repo):
            first = monitor.run_monitor("external-prs", self.paths)
            second = monitor.run_monitor("external-prs", self.paths)

        self.assertEqual(first["eventsFound"], 1)
        self.assertEqual(first["eventsDelivered"], 1)
        self.assertEqual(second["eventsFound"], 0)
        with monitor.connect(self.paths) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM monitor_events").fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM monitor_deliveries WHERE status='delivered'").fetchone()[0], 1)
        events_log = self.paths["monitors"] / "external-prs" / "logs" / "events.jsonl"
        self.assertEqual(len(events_log.read_text(encoding="utf-8").splitlines()), 1)

    def test_failed_output_retries_without_repeating_delivered_output(self):
        self.definition["outputs"] = ["log", "todo_local"]
        self.definition_file.write_text(json.dumps(self.definition), encoding="utf-8")
        self.create_monitor()
        pr_items = [{
            "number": 9, "title": "Retry test", "url": "https://github.com/acme/app/pull/9",
            "author": {"login": "contributor"}, "isDraft": False,
            "createdAt": "2099-01-01T00:00:00Z",
        }]
        calls = []

        def first_delivery(kind, event, monitor_id, run_id, paths):
            calls.append(kind)
            if kind == "todo_local":
                raise monitor.MonitorError("Todo endpoint temporarily unavailable")

        with (
            patch.object(monitor, "gh_login", return_value="primary"),
            patch.object(monitor, "gh_prs", side_effect=lambda repo: pr_items if repo == "acme/app" else []),
            patch.object(monitor, "deliver", side_effect=first_delivery),
        ):
            first = monitor.run_monitor("external-prs", self.paths)
        self.assertEqual(first["status"], "partial")
        self.assertEqual(calls, ["log", "todo_local"])

        def recovered_delivery(kind, event, monitor_id, run_id, paths):
            calls.append(kind)

        with (
            patch.object(monitor, "gh_login", return_value="primary"),
            patch.object(monitor, "gh_prs", side_effect=lambda repo: pr_items if repo == "acme/app" else []),
            patch.object(monitor, "deliver", side_effect=recovered_delivery),
        ):
            second = monitor.run_monitor("external-prs", self.paths)
        self.assertEqual(second["status"], "completed")
        self.assertEqual(calls, ["log", "todo_local", "todo_local"])
        with monitor.connect(self.paths) as db:
            states = {row["output_key"]: row["status"] for row in db.execute("SELECT output_key,status FROM monitor_deliveries")}
        self.assertEqual(states, {"log": "delivered", "todo_local": "delivered"})

    def test_event_marker_searches_nested_todo_tasks(self):
        marker = "<!-- MANUL_MONITOR_EVENT:v1:abc -->"
        tasks = [{"description": "root", "subTasks": [{"description": "child " + marker}]}]
        self.assertTrue(monitor.contains_marker(tasks, marker))
        self.assertFalse(monitor.contains_marker(tasks, "missing"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
