#!/usr/bin/env python3
"""Hermetic tests for the restricted Manul Streamable HTTP MCP client."""

import importlib.util
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


CLIENT_PATH = Path(__file__).with_name("todo-mcp-client.py")
SPEC = importlib.util.spec_from_file_location("todo_mcp_client", CLIENT_PATH)
CLIENT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLIENT)


class FakeMcpHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests = []
    token = "fixture-token"

    def log_message(self, *_args):
        return

    def _respond(self, payload=None, status=200, session=False):
        body = b"" if payload is None else json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if session:
            self.send_header("Mcp-Session-Id", "fixture-session")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_POST(self):
        if self.headers.get("Authorization") != f"Bearer {self.token}":
            self._respond(status=401)
            return
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        self.requests.append((payload, dict(self.headers)))
        method = payload.get("method")
        if method == "initialize":
            self._respond(
                {
                    "jsonrpc": "2.0",
                    "id": payload["id"],
                    "result": {
                        "protocolVersion": CLIENT.PROTOCOL_VERSION,
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "fixture", "version": "1"},
                    },
                },
                session=True,
            )
        elif method == "notifications/initialized":
            self._respond(status=202)
        elif method == "tools/call":
            tool_name = payload["params"]["name"]
            if tool_name in {"create_task", "todo_create_task"}:
                arguments = payload["params"]["arguments"]
                task = arguments if tool_name == "create_task" else arguments["task"]
                result_value = {
                    "id": 8,
                    "description": task["description"],
                    "parentTaskId": task["parentTaskId"],
                    "isToDo": True,
                }
            else:
                result_value = [{"id": 7, "description": "Fixture task", "subTasks": []}]
            self._respond(
                {
                    "jsonrpc": "2.0",
                    "id": payload["id"],
                    "result": {
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(result_value),
                            }
                        ],
                    },
                }
            )
        else:
            self._respond(
                {
                    "jsonrpc": "2.0",
                    "id": payload.get("id"),
                    "error": {"code": -32601, "message": "method not found"},
                }
            )


class TodoMcpClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        FakeMcpHandler.requests = []
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeMcpHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/mcp"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def setUp(self):
        FakeMcpHandler.requests.clear()

    def test_initialize_notification_and_tool_call_use_same_session(self):
        client = CLIENT.StreamableHttpClient(self.url, "fixture-token", 3)
        result = client.call_tool("todo_list_tasks", {})
        self.assertEqual(7, result[0]["id"])
        self.assertEqual(
            [
                "initialize",
                "notifications/initialized",
                "tools/call",
            ],
            [item[0]["method"] for item in FakeMcpHandler.requests],
        )
        initialize_headers = FakeMcpHandler.requests[0][1]
        self.assertEqual("Bearer fixture-token", initialize_headers["Authorization"])
        self.assertNotIn("Mcp-Session-Id", initialize_headers)
        self.assertNotIn("MCP-Protocol-Version", initialize_headers)
        for _, raw_headers in FakeMcpHandler.requests[1:]:
            headers = {name.lower(): value for name, value in raw_headers.items()}
            self.assertEqual("Bearer fixture-token", headers["authorization"])
            self.assertEqual("fixture-session", headers["mcp-session-id"])
            self.assertEqual(CLIENT.PROTOCOL_VERSION, headers["mcp-protocol-version"])
        self.assertEqual("todo_list_tasks", FakeMcpHandler.requests[-1][0]["params"]["name"])

    def test_tool_allowlist_rejects_arbitrary_operations(self):
        client = CLIENT.StreamableHttpClient(self.url, "fixture-token", 3)
        with self.assertRaises(CLIENT.McpClientError):
            client.call_tool("delete_everything", {})
        self.assertEqual([], FakeMcpHandler.requests)

    def test_remote_partial_update_tool_is_allowed(self):
        client = CLIENT.StreamableHttpClient(self.url, "fixture-token", 3)
        result = client.call_tool(
            "todo_update_task",
            {"id": 7, "task": {"isToDo": False}},
        )
        self.assertEqual(7, result[0]["id"])
        self.assertEqual("todo_update_task", FakeMcpHandler.requests[-1][0]["params"]["name"])

    def test_local_and_remote_create_tools_are_allowlisted_and_receive_exact_arguments(self):
        cases = [
            (
                "create_task",
                {
                    "description": "Local report result",
                    "parentTaskId": 42,
                    "highestPriorityAsDefault": False,
                },
            ),
            (
                "todo_create_task",
                {
                    "task": {
                        "description": "Remote report result",
                        "parentTaskId": 77,
                        "highestPriorityAsDefault": False,
                    }
                },
            ),
        ]
        for tool_name, arguments in cases:
            with self.subTest(tool=tool_name):
                FakeMcpHandler.requests.clear()
                client = CLIENT.StreamableHttpClient(self.url, "fixture-token", 3)
                result = client.call_tool(tool_name, arguments)
                self.assertEqual(8, result["id"])
                self.assertEqual(
                    arguments["description"] if tool_name == "create_task" else arguments["task"]["description"],
                    result["description"],
                )
                call = [
                    payload for payload, _ in FakeMcpHandler.requests
                    if payload.get("method") == "tools/call"
                ][0]
                self.assertEqual(tool_name, call["params"]["name"])
                self.assertEqual(arguments, call["params"]["arguments"])

    def test_url_embedded_credentials_are_rejected(self):
        with self.assertRaises(CLIENT.McpClientError):
            CLIENT.StreamableHttpClient("http://user:password@example.test/mcp", "token", 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
