#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import sys
import unittest
from unittest.mock import patch

SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

SPEC = importlib.util.spec_from_file_location(
    "todo_remote_create_task", SCRIPT_DIR / "todo-remote-create-task.py"
)
assert SPEC and SPEC.loader
CREATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CREATOR
SPEC.loader.exec_module(CREATOR)


class FakeMcpClient:
    calls: list[tuple[str, dict]]

    def __init__(self, url: str, token: str, timeout: float) -> None:
        self.url = url
        self.token = token
        self.timeout = timeout
        self.calls = []

    def call_tool(self, name: str, arguments: dict):
        self.calls.append((name, arguments))
        if name == "todo_create_task":
            task = arguments["task"]
            self.created = {
                "id": 912,
                **task,
            }
            return self.created
        if name == "todo_list_tasks":
            return [{"id": 100, "subTasks": [self.created]}]
        raise AssertionError(name)


class TodoRemoteCreateTaskTests(unittest.TestCase):
    def test_required_share_is_added_and_existing_user_share_is_upgraded(self):
        task = {
            "description": "Manul generated task",
            "shares": [
                {"userId": "31", "permission": "VIEWER"},
                {"userId": "88", "permission": "VIEWER"},
            ],
        }
        result = CREATOR.add_required_share(task, "88")
        self.assertEqual(
            [
                {"userId": "31", "permission": "VIEWER"},
                {"userId": "88", "permission": "EDITOR_AND_VIEWER"},
            ],
            result["shares"],
        )
        self.assertEqual("VIEWER", task["shares"][1]["permission"])

    def test_share_is_added_when_no_shares_are_provided(self):
        result = CREATOR.add_required_share({"description": "New task"}, "88")
        self.assertEqual(
            [{"userId": "88", "permission": "EDITOR_AND_VIEWER"}],
            result["shares"],
        )
        self.assertTrue(result["isToDo"])

    def test_rejects_missing_or_invalid_recipient_id(self):
        for value in ("", "0", "-1", "mariusz.marzec00@gmail.com", "88x"):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    CREATOR.required_share_user_id({"FITEO_MANUL_SHARE_USER_ID": value})

    def test_no_operator_pat_fallback(self):
        with patch.dict(
            os.environ,
            {
                "FITEO_BASE_URL": "https://fiteo.example.test",
                "FITEO_PAT": "operator-token",
            },
            clear=True,
        ):
            with self.assertRaises(ValueError):
                CREATOR.create_and_verify({"description": "Should fail closed"})

    def test_create_is_followed_by_readback_and_share_verification(self):
        fake = FakeMcpClient("", "", 0)
        with patch.dict(
            os.environ,
            {
                "FITEO_BASE_URL": "https://fiteo.example.test",
                "FITEO_MANUL_PAT": "manul-token",
                "FITEO_MANUL_SHARE_USER_ID": "88",
            },
            clear=True,
        ), patch.object(CREATOR, "StreamableHttpClient", return_value=fake) as client_factory:
            result = CREATOR.create_and_verify(
                {"description": "Manul created task", "parentTaskId": 100}
            )

        client_factory.assert_called_once_with(
            "https://fiteo.example.test/mcp", "manul-token", 30.0
        )
        self.assertEqual(912, result["id"])
        self.assertEqual(
            ["todo_create_task", "todo_list_tasks"],
            [name for name, _ in fake.calls],
        )
        self.assertEqual(
            [{"userId": "88", "permission": "EDITOR_AND_VIEWER"}],
            fake.calls[0][1]["task"]["shares"],
        )

    def test_readback_without_share_fails(self):
        class UnsharedFake(FakeMcpClient):
            def call_tool(self, name: str, arguments: dict):
                if name == "todo_create_task":
                    self.created = {"id": 913, **arguments["task"], "shares": []}
                    return self.created
                if name == "todo_list_tasks":
                    return [self.created]
                raise AssertionError(name)

        fake = UnsharedFake("", "", 0)
        with patch.dict(
            os.environ,
            {
                "FITEO_BASE_URL": "https://fiteo.example.test",
                "FITEO_MANUL_PAT": "manul-token",
                "FITEO_MANUL_SHARE_USER_ID": "88",
            },
            clear=True,
        ), patch.object(CREATOR, "StreamableHttpClient", return_value=fake):
            with self.assertRaises(CREATOR.McpClientError):
                CREATOR.create_and_verify({"description": "Unshared task"})


if __name__ == "__main__":
    unittest.main()
