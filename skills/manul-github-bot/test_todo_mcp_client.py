#!/usr/bin/env python3
"""Hermetic tests for the restricted Streamable HTTP Todo MCP client."""

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


class McpHandler(BaseHTTPRequestHandler):
    requests = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.loads(body or b"{}")
        self.requests.append((payload, dict(self.headers)))
        method = payload.get("method")
        if method == "initialize":
            response = {
                "jsonrpc": "2.0", "id": payload["id"],
                "result": {
                    "protocolVersion": CLIENT.PROTOCOL_VERSION,
                    "capabilities": {},
                    "serverInfo": {"name": "fixture", "version": "1"},
                },
            }
        elif method == "tools/list":
            response = {"jsonrpc": "2.0", "id": payload["id"], "result": {"tools": [{"name": "todo_list_tasks"}]}}
        elif method == "tools/call":
            response = {"jsonrpc": "2.0", "id": payload["id"], "result": {"content": [{"type": "text", "text": "[]"}]}}
        else:
            response = {"jsonrpc": "2.0", "id": payload.get("id"), "result": {}}
        data = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Mcp-Session-Id", "fixture-session")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        pass


class TodoMcpClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        McpHandler.requests = []
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), McpHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/mcp"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def test_client_initializes_lists_and_calls_allowlisted_tool(self):
        client = CLIENT.StreamableHttpClient(self.url, None, 2)
        client.initialize()
        self.assertEqual("fixture-session", client.session_id)
        self.assertEqual([{"name": "todo_list_tasks"}], client.list_tools())
        result = client.call_tool("todo_list_tasks", {})
        self.assertEqual([], result)
        methods = [payload.get("method") for payload, _ in McpHandler.requests]
        self.assertIn("initialize", methods)
        self.assertIn("notifications/initialized", methods)
        self.assertIn("tools/list", methods)
        self.assertIn("tools/call", methods)

    def test_client_refuses_non_allowlisted_tool_before_network_call(self):
        before = len(McpHandler.requests)
        client = CLIENT.StreamableHttpClient(self.url, None, 2)
        with self.assertRaises(CLIENT.McpClientError):
            client.call_tool("delete_everything", {})
        self.assertEqual(before, len(McpHandler.requests))

    def test_localhost_is_loopback(self):
        self.assertTrue(CLIENT.is_loopback_url("http://127.0.0.1:8765/mcp"))
        self.assertTrue(CLIENT.is_loopback_url("http://localhost:8765/mcp"))
        self.assertFalse(CLIENT.is_loopback_url("https://example.com/mcp"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
