#!/usr/bin/env python3
"""Normalize OpenCode's agent-list output without weakening role validation.

Some CLI/runtime versions may write startup or diagnostic text to stdout before
the JSON payload. The discovery contract only needs the canonical agent IDs,
so strip terminal control sequences and extract a valid JSON agent array while
still rejecting arbitrary or malformed output.
"""
from __future__ import annotations

import json
import re
import sys
from typing import Any

_ANSI_ESCAPE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|[@-_])|\x9b[0-?]*[ -/]*[@-~]", re.IGNORECASE)
_WRAPPER_KEYS = ("agents", "data", "result")


def _valid_agents(value: Any) -> list[dict[str, Any]] | None:
    if isinstance(value, list):
        if all(
            isinstance(agent, dict)
            and isinstance(agent.get("id"), str)
            and bool(agent["id"].strip())
            for agent in value
        ):
            return value
        return None
    if isinstance(value, dict):
        for key in _WRAPPER_KEYS:
            candidate = value.get(key)
            if isinstance(candidate, list):
                parsed = _valid_agents(candidate)
                if parsed is not None:
                    return parsed
    return None


def parse_agent_list(stdout: str) -> tuple[str, list[dict[str, Any]] | str]:
    """Return (ok, agents) for a raw, wrapped, or log-prefixed JSON listing."""
    cleaned = _ANSI_ESCAPE.sub("", stdout).lstrip("\ufeff")
    decoder = json.JSONDecoder()

    # Prefer the normal contract (one JSON document at the beginning). If a
    # runtime banner/log line precedes it, scan later JSON value boundaries.
    first = len(cleaned) - len(cleaned.lstrip())
    candidates = [first]
    seen = {first}
    for index, char in enumerate(cleaned):
        if char in "[{" and index not in seen:
            candidates.append(index)
            seen.add(index)
    for offset in candidates:
        try:
            value, _end = decoder.raw_decode(cleaned, offset)
        except json.JSONDecodeError:
            continue
        agents = _valid_agents(value)
        if agents is not None:
            return "ok", agents

    return "error", "OpenCode debug agents output did not contain a valid JSON agent list"


def main() -> int:
    status, result = parse_agent_list(sys.stdin.read())
    if status != "ok":
        print(result, file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
