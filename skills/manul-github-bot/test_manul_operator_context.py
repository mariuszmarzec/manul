#!/usr/bin/env python3
"""Hermetic tests for the bounded, read-only Manul operator context builder."""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("manul-operator-context.py")


class OperatorContextTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="manul-operator-context-")
        self.root = Path(self.temp.name)
        self.db = self.root / "manul.db"
        self.logs = self.root / "logs"
        self.logs.mkdir()
        connection = sqlite3.connect(self.db)
        connection.execute(
            """
            CREATE TABLE processed_comments (
                commentId TEXT,
                repository TEXT,
                issueNumber INTEGER,
                status TEXT,
                taskSourceType TEXT,
                taskSourceId TEXT,
                agent TEXT,
                attempts INTEGER,
                createdAt TEXT,
                agentStartedAt TEXT,
                processedAt TEXT,
                prompt TEXT,
                resultSummary TEXT,
                context TEXT
            )
            """
        )
        connection.executemany(
            """
            INSERT INTO processed_comments
            (commentId, repository, issueNumber, status, taskSourceType,
             taskSourceId, agent, attempts, createdAt, agentStartedAt,
             processedAt, prompt, resultSummary, context)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                (
                    "running-1", "owner/repo", 10, "running", "github_issues",
                    "10", "coder", 2, "2026-11-11 10:00:00", "2026-11-11 10:01:00",
                    None, "Inspect current implementation", None, None,
                ),
                (
                    "done-1", "owner/repo", 11, "completed", "todo_remote_mcp",
                    "116372@fingerprint", "researcher", 1, "2026-11-10 10:00:00",
                    "2026-11-10 10:01:00", "2026-11-10 10:05:00",
                    "Summarize the fix", "Verified result summary", None,
                ),
                (
                    "old-1", "owner/repo", 12, "completed", "github_issues",
                    "12", "coder", 1, "2026-10-01 10:00:00", None,
                    "2026-10-01 10:10:00", "Old task", "Old summary", None,
                ),
            ],
        )
        connection.commit()
        connection.close()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_builder(self, output: Path, *, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(extra_env or {})
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--db", str(self.db),
                "--logs-dir", str(self.logs),
                "--output", str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def digest(self) -> str:
        return hashlib.sha256(self.db.read_bytes()).hexdigest()

    def test_snapshot_is_bounded_recent_and_read_only(self) -> None:
        (self.logs / "lifecycle.log").write_text(
            "TASK_STARTED task=running-1\nTASK_DONE task=done-1\n",
            encoding="utf-8",
        )
        before = self.digest()
        output = self.root / "snapshot.json"
        result = self.run_builder(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(payload["activeTaskCountInRecent300Rows"], 1)
        self.assertEqual({task["taskId"] for task in payload["tasks"]}, {"running-1", "done-1"})
        done = next(task for task in payload["tasks"] if task["taskId"] == "done-1")
        self.assertEqual(done["sourceId"], "116372")
        self.assertEqual(done["resultSummary"], "Verified result summary")
        self.assertIn("lifecycle.log", payload["logs"])
        self.assertEqual(before, self.digest(), "context collection must not mutate the source DB")
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_redacts_environment_and_log_secrets(self) -> None:
        (self.logs / "daemon.log").write_text(
            "Authorization: Bearer env-secret\n"
            "request token=inline-secret completed\n",
            encoding="utf-8",
        )
        output = self.root / "snapshot.json"
        result = self.run_builder(
            output,
            extra_env={"MANUL_OPERATOR_TEST_TOKEN": "env-secret"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        content = output.read_text(encoding="utf-8")
        self.assertNotIn("env-secret", content)
        self.assertNotIn("inline-secret", content)
        self.assertIn("[REDACTED]", content)

    def test_skips_symlinked_log_files(self) -> None:
        outside = self.root / "outside.log"
        outside.write_text("external evidence", encoding="utf-8")
        (self.logs / "daemon.log").symlink_to(outside)
        output = self.root / "snapshot.json"
        result = self.run_builder(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(output.read_text(encoding="utf-8"))
        self.assertNotIn("daemon.log", payload["logs"])
        self.assertNotIn("external evidence", output.read_text(encoding="utf-8"))

    def test_missing_database_fails_without_creating_it(self) -> None:
        missing = self.root / "missing.db"
        output = self.root / "snapshot.json"
        result = subprocess.run(
            [
                sys.executable, str(SCRIPT),
                "--db", str(missing),
                "--logs-dir", str(self.logs),
                "--output", str(output),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(missing.exists())
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
