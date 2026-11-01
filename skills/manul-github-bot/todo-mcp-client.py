#!/usr/bin/env python3
"""Small, allow-listed Streamable HTTP MCP client for Manul's Todo task sources."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from typing import Any
from urllib.parse import urlsplit


ALLOWED_TOOLS = {
    "list_tasks",
    "create_task",
    "mark_tasks_done",
    "todo_list_tasks",
    "todo_create_task",
    "todo_mark_tasks",
    "todo_update_task",
}
PROTOCOL_VERSION = "2025-06-18"


class McpClientError(RuntimeError):
    pass


def parse_payload(body: bytes, content_type: str) -> dict[str, Any] | None:
    if not body:
        return None
    text = body.decode("utf-8", errors="replace").strip()
    if "text/event-stream" in content_type.lower():
        data_lines = [
            line[5:].strip()
            for line in text.splitlines()
            if line.startswith("data:")
        ]
        for data in reversed(data_lines):
            if data and data != "[DONE]":
                try:
                    value = json.loads(data)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict):
                    return value
        raise McpClientError("MCP server returned an unreadable event stream")
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise McpClientError("MCP server returned invalid JSON") from error
    if not isinstance(value, dict):
        raise McpClientError("MCP server returned an unexpected JSON value")
    return value


class StreamableHttpClient:
    def __init__(self, url: str, token: str, timeout: float) -> None:
        parsed = urlsplit(url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise McpClientError("MCP URL must be an absolute HTTP(S) URL")
        if parsed.username or parsed.password or parsed.fragment:
            raise McpClientError("MCP URL must not contain credentials or a fragment")
        self.url = url
        self.token = token
        self.timeout = timeout
        self.session_id: str | None = None
        self.request_id = 0
        self.initialized = False
        self.protocol_version = PROTOCOL_VERSION

    def post(self, payload: dict[str, Any]) -> dict[str, Any] | None:
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self.session_id:
            headers["Mcp-Session-Id"] = self.session_id
        if self.initialized:
            headers["MCP-Protocol-Version"] = self.protocol_version
        request = urllib.request.Request(
            self.url,
            data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                self.session_id = response.headers.get("Mcp-Session-Id") or self.session_id
                return parse_payload(response.read(), response.headers.get("Content-Type", ""))
        except urllib.error.HTTPError as error:
            # Do not include request headers, URL credentials, or response bodies in diagnostics.
            if error.code == 401:
                raise McpClientError("MCP authentication failed (HTTP 401)") from None
            if error.code in {404, 405}:
                raise McpClientError(f"MCP endpoint rejected the request (HTTP {error.code})") from None
            raise McpClientError(f"MCP request failed (HTTP {error.code})") from None
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            raise McpClientError(f"MCP endpoint is unavailable ({type(error).__name__})") from None

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self.request_id += 1
        payload: dict[str, Any] = {
            "jsonrpc": "2.0",
            "id": self.request_id,
            "method": method,
        }
        if params is not None:
            payload["params"] = params
        response = self.post(payload)
        if not isinstance(response, dict):
            raise McpClientError(f"MCP server returned no response for {method}")
        if "error" in response:
            error = response.get("error")
            message = error.get("message") if isinstance(error, dict) else None
            raise McpClientError(message or f"MCP request {method} failed")
        result = response.get("result")
        if not isinstance(result, dict):
            raise McpClientError(f"MCP server returned an invalid result for {method}")
        return result

    def notify_initialized(self) -> None:
        self.post(
            {
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
            }
        )

    def call_tool(self, name: str, arguments: dict[str, Any]) -> Any:
        if name not in ALLOWED_TOOLS:
            raise McpClientError("Tool is not in the Manul Todo MCP allow-list")
        initialized = self.request(
            "initialize",
            {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {
                    "name": "manul-todo-task-source",
                    "version": "1.0.0",
                },
            },
        )
        negotiated_version = initialized.get("protocolVersion")
        if not isinstance(negotiated_version, str) or not negotiated_version:
            raise McpClientError("MCP initialize response did not negotiate a protocol version")
        self.protocol_version = negotiated_version
        self.initialized = True
        self.notify_initialized()
        result = self.request(
            "tools/call",
            {
                "name": name,
                "arguments": arguments,
            },
        )
        if result.get("isError") is True:
            contents = result.get("content")
            detail = "Todo MCP tool call failed"
            if isinstance(contents, list):
                for item in contents:
                    if isinstance(item, dict) and isinstance(item.get("text"), str):
                        detail = item["text"][:500]
                        break
            raise McpClientError(detail)
        contents = result.get("content")
        if not isinstance(contents, list):
            raise McpClientError("Todo MCP tool returned no content")
        text_items = [
            item["text"]
            for item in contents
            if isinstance(item, dict)
            and item.get("type") == "text"
            and isinstance(item.get("text"), str)
        ]
        if not text_items:
            raise McpClientError("Todo MCP tool returned no text content")
        if len(text_items) == 1:
            try:
                return json.loads(text_items[0])
            except json.JSONDecodeError:
                return text_items[0]
        return text_items


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--token-env", required=True)
    parser.add_argument("--tool", required=True, choices=sorted(ALLOWED_TOOLS))
    parser.add_argument("--arguments", default="{}")
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()

    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", args.token_env):
        parser.error("--token-env must be an environment variable name")
    if not 1 <= args.timeout <= 120:
        parser.error("--timeout must be between 1 and 120 seconds")

    token = os.environ.get(args.token_env, "")
    if not token:
        print(f"ERROR: required MCP token environment variable is missing: {args.token_env}", file=sys.stderr)
        return 2
    try:
        arguments = json.loads(args.arguments)
    except json.JSONDecodeError:
        print("ERROR: --arguments must be valid JSON", file=sys.stderr)
        return 2
    if not isinstance(arguments, dict):
        print("ERROR: --arguments must be a JSON object", file=sys.stderr)
        return 2

    try:
        result = StreamableHttpClient(args.url, token, args.timeout).call_tool(args.tool, arguments)
    except McpClientError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
