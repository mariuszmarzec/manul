#!/usr/bin/env python3
"""Create a Fiteo Todo task through Manul's enforced share policy."""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any
from urllib.parse import urlsplit

import importlib.util
from pathlib import Path

# The canonical MCP client keeps its executable hyphenated filename. Load it
# by path so this helper works the same from the Manul runtime symlink.
_client_path = Path(__file__).resolve().with_name("todo-mcp-client.py")
_client_spec = importlib.util.spec_from_file_location("manul_todo_mcp_client", _client_path)
if _client_spec is None or _client_spec.loader is None:
    raise ImportError(f"Cannot load Manul Todo MCP client from {_client_path}")
_client_module = importlib.util.module_from_spec(_client_spec)
sys.modules[_client_spec.name] = _client_module
_client_spec.loader.exec_module(_client_module)
McpClientError = _client_module.McpClientError
StreamableHttpClient = _client_module.StreamableHttpClient


ALLOWED_TASK_FIELDS = {
    "description",
    "parentTaskId",
    "priority",
    "highestPriorityAsDefault",
    "scheduler",
    "isToDo",
    "expirationDate",
    "shares",
}


def required_share_user_id(environ: dict[str, str] | None = None) -> str:
    env = os.environ if environ is None else environ
    value = env.get("FITEO_MANUL_SHARE_USER_ID", "")
    if not value.isdecimal() or int(value) <= 0:
        raise ValueError(
            "FITEO_MANUL_SHARE_USER_ID must contain the numeric Fiteo user ID "
            "for the configured Mariusz recipient"
        )
    return value


def validate_task(task: dict[str, Any]) -> dict[str, Any]:
    result = dict(task)
    unknown = set(result) - ALLOWED_TASK_FIELDS
    if unknown:
        raise ValueError("Unsupported Todo task field(s): " + ", ".join(sorted(unknown)))

    description = result.get("description")
    if not isinstance(description, str) or not description.strip():
        raise ValueError("description must be a non-empty string")

    parent_id = result.get("parentTaskId")
    if parent_id is not None and (
        isinstance(parent_id, bool) or not isinstance(parent_id, int) or parent_id <= 0
    ):
        raise ValueError("parentTaskId must be a positive integer or null")
    if parent_id is not None and result.get("scheduler") is not None:
        raise ValueError("Fiteo does not allow scheduled subtasks")

    existing = result.get("shares") or []
    if not isinstance(existing, list):
        raise ValueError("shares must be an array")
    result.setdefault("isToDo", True)
    return result


def add_required_share(task: dict[str, Any], user_id: str) -> dict[str, Any]:
    result = validate_task(task)
    if result.get("parentTaskId") is not None:
        raise ValueError("Direct task shares are only added to root tasks")

    existing = result.get("shares") or []
    shares: list[dict[str, str]] = []
    found = False
    for item in existing:
        if not isinstance(item, dict):
            raise ValueError("each task share must be an object")
        share_user = str(item.get("userId", ""))
        if share_user == user_id:
            if not found:
                shares.append(
                    {"userId": user_id, "permission": "EDITOR_AND_VIEWER"}
                )
                found = True
            continue
        permission = item.get("permission")
        if not isinstance(permission, str):
            raise ValueError("each task share requires a permission string")
        shares.append({"userId": share_user, "permission": permission})

    if not found:
        shares.append({"userId": user_id, "permission": "EDITOR_AND_VIEWER"})
    result["shares"] = shares
    return result


def prepare_task_payload(task: dict[str, Any]) -> dict[str, Any]:
    result = validate_task(task)
    if result.get("parentTaskId") is not None:
        # Fiteo subtasks inherit access from their parent task. Do not create a
        # second, independent share list for a child of an already visible task.
        result.pop("shares", None)
        return result
    return add_required_share(result, required_share_user_id())


def find_task(value: Any, task_id: int) -> dict[str, Any] | None:
    if isinstance(value, list):
        for item in value:
            match = find_task(item, task_id)
            if match is not None:
                return match
        return None
    if not isinstance(value, dict):
        return None
    current_id = value.get("id")
    if not isinstance(current_id, bool) and current_id == task_id:
        return value
    return find_task(value.get("subTasks") or [], task_id)


def find_child_task(value: Any, parent_id: int, task_id: int) -> dict[str, Any] | None:
    """Find a task only when it is returned as a direct child of its parent."""
    if isinstance(value, list):
        for item in value:
            match = find_child_task(item, parent_id, task_id)
            if match is not None:
                return match
        return None
    if not isinstance(value, dict):
        return None

    if value.get("id") == parent_id:
        for child in value.get("subTasks") or []:
            if (
                isinstance(child, dict)
                and child.get("id") == task_id
                and child.get("parentTaskId") == parent_id
            ):
                return child

    return find_child_task(value.get("subTasks") or [], parent_id, task_id)


def has_required_share(task: dict[str, Any], user_id: str) -> bool:
    shares = task.get("shares")
    if not isinstance(shares, list):
        return False
    return any(
        isinstance(item, dict)
        and str(item.get("userId", "")) == user_id
        and item.get("permission") == "EDITOR_AND_VIEWER"
        for item in shares
    )


def create_and_verify(task: dict[str, Any]) -> dict[str, Any]:
    base_url = os.environ.get("FITEO_BASE_URL", "").rstrip("/")
    token = os.environ.get("FITEO_MANUL_PAT", "")
    if not base_url:
        raise ValueError("FITEO_BASE_URL is missing from the Manul runtime environment")
    if not token:
        raise ValueError("FITEO_MANUL_PAT is missing; refusing to use the operator PAT")

    parsed = urlsplit(base_url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError("FITEO_BASE_URL must be an absolute HTTPS URL")
    url = base_url if parsed.path.rstrip("/").endswith("/mcp") else base_url + "/mcp"

    client = StreamableHttpClient(url, token, 30.0)
    task_payload = prepare_task_payload(task)
    parent_id = task_payload.get("parentTaskId")

    # A subtask can inherit access only from a parent that Manul can already
    # see. Check this before creating anything so a bad parent ID cannot leave
    # an orphaned or inaccessible task behind.
    if parent_id is not None:
        current_tasks = client.call_tool("todo_list_tasks", {})
        if find_task(current_tasks, parent_id) is None:
            raise McpClientError(
                f"Parent task {parent_id} is not visible to Manul; refusing to create a subtask"
            )

    created = client.call_tool("todo_create_task", {"task": task_payload})
    if not isinstance(created, dict):
        raise McpClientError("Fiteo returned no created task object")
    task_id = created.get("id")
    if isinstance(task_id, bool) or not isinstance(task_id, int) or task_id <= 0:
        raise McpClientError("Fiteo returned a created task without a valid ID")

    current_tasks = client.call_tool("todo_list_tasks", {})
    if parent_id is not None:
        verified = find_child_task(current_tasks, parent_id, task_id)
        if verified is None:
            raise McpClientError(
                f"Subtask {task_id} was created but was not returned beneath parent task {parent_id}"
            )
        if verified.get("parentTaskId") != parent_id:
            raise McpClientError(
                f"Subtask {task_id} read-back did not preserve parent task {parent_id}"
            )
    else:
        user_id = required_share_user_id()
        verified = find_task(current_tasks, task_id)
        if verified is None:
            raise McpClientError(
                f"Root task {task_id} was created but could not be read back"
            )
        if not has_required_share(verified, user_id):
            raise McpClientError(
                f"Root task {task_id} was created but its required Mariusz share was not present on read-back"
            )
    return verified


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--task-json", required=True, help="JSON object matching Fiteo CreateTaskDto")
    args = parser.parse_args()
    try:
        task = json.loads(args.task_json)
        if not isinstance(task, dict):
            raise ValueError("task-json must be a JSON object")
        result = create_and_verify(task)
    except (json.JSONDecodeError, ValueError, McpClientError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
