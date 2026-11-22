#!/usr/bin/env python3
"""Fail-closed repository policy inspection for Manul Team Workflow."""
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

TRACKER_TYPES = ("github_issues", "todo_local_mcp", "todo_remote_mcp")
KEY_RE = re.compile(r"([A-Za-z][A-Za-z0-9_-]*):(?:\s*(.*))?")


def emit(ok: bool, **values: Any) -> int:
    print(json.dumps({"ok": ok, **values}, ensure_ascii=False, sort_keys=True))
    return 0 if ok else 2


def scalar(raw: str) -> str:
    value = raw.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    if any(ch in value for ch in "{}[]&*!|>"):
        raise ValueError("unsupported YAML scalar syntax")
    return value


def read_team_config(repo_root: Path) -> dict[str, Any]:
    directory = repo_root / ".manul"
    if directory.is_symlink():
        raise ValueError(".manul must not be a symlink")
    if not directory.exists():
        return {}
    if not directory.is_dir():
        raise ValueError(".manul must be a directory")

    path = directory / "team.yaml"
    if not path.exists():
        return {}
    if path.is_symlink() or not path.is_file():
        raise ValueError(".manul/team.yaml must be a regular file")

    values: dict[str, Any] = {}
    trackers: list[str] | None = None
    in_trackers = False
    for number, original in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = re.sub(r"\s+#.*$", "", original).rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            match = KEY_RE.fullmatch(line.strip())
            if not match:
                raise ValueError(f"unsupported YAML syntax at line {number}")
            key, raw = match.group(1), match.group(2) or ""
            if key not in {"version", "prApprovedByMan", "trackers"}:
                raise ValueError(f"unsupported team config key: {key}")
            if key in values or (key == "trackers" and trackers is not None):
                raise ValueError(f"duplicate team config key: {key}")
            if key == "trackers":
                if raw:
                    raise ValueError("trackers must be a YAML list")
                trackers = []
                in_trackers = True
                continue
            in_trackers = False
            parsed = scalar(raw)
            if key == "version":
                if parsed != "1":
                    raise ValueError("unsupported or missing team config version (expected 1)")
                values[key] = 1
            else:
                if parsed not in {"true", "false"}:
                    raise ValueError("prApprovedByMan must be true or false")
                values[key] = parsed == "true"
        elif indent == 2 and in_trackers:
            match = re.fullmatch(r"\s*-\s+(.+?)\s*", line)
            if not match or trackers is None:
                raise ValueError(f"invalid tracker entry at line {number}")
            tracker = scalar(match.group(1))
            if tracker not in TRACKER_TYPES:
                raise ValueError(f"unsupported tracker type: {tracker}")
            if tracker in trackers:
                raise ValueError(f"duplicate tracker type: {tracker}")
            trackers.append(tracker)
        else:
            raise ValueError(f"unexpected indentation or nested key at line {number}")

    if values.get("version") != 1:
        raise ValueError("team config requires version: 1")
    if trackers is not None:
        if not trackers:
            raise ValueError("trackers must contain at least one provider")
        values["trackers"] = trackers
    return values


def enabled_task_sources(manul_config: dict[str, Any]) -> list[str]:
    configured = manul_config.get("taskSources")
    if configured is None:
        return ["github_issues"]
    if not isinstance(configured, list):
        raise ValueError("Manul taskSources must be an array")
    enabled: list[str] = []
    for item in configured:
        if not isinstance(item, dict):
            raise ValueError("each Manul taskSources entry must be an object")
        source_type = item.get("type")
        if not isinstance(source_type, str) or not source_type:
            raise ValueError("each Manul taskSources entry requires a type")
        is_enabled = item.get("enabled", source_type == "github_issues")
        if not isinstance(is_enabled, bool):
            raise ValueError(f"taskSources[{source_type}].enabled must be a boolean")
        if is_enabled:
            enabled.append(source_type)
    return enabled


def resolve_trackers(config: dict[str, Any], manul_config: dict[str, Any]) -> list[str]:
    enabled = enabled_task_sources(manul_config)
    explicit = config.get("trackers")
    if explicit is not None:
        missing = [provider for provider in explicit if provider not in enabled]
        if missing:
            raise ValueError(
                "configured team tracker(s) are disabled or unavailable in Manul taskSources: "
                + ", ".join(missing)
            )
        return explicit

    if "github_issues" in enabled:
        return ["github_issues"]

    todo_enabled = [
        provider for provider in TRACKER_TYPES
        if provider.startswith("todo_") and provider in enabled
    ]
    if len(todo_enabled) == 1:
        return todo_enabled
    if len(todo_enabled) > 1:
        raise ValueError(
            "multiple Todo providers are enabled; set an explicit trackers list in .manul/team.yaml"
        )
    raise ValueError(
        "no task tracker is enabled for Team Workflow; enable github_issues or a Todo provider in Manul config"
    )


def inspect(args: argparse.Namespace) -> int:
    try:
        root = Path(args.repo_root).resolve(strict=True)
        if not root.is_dir():
            return emit(False, mode="invalid", error="repository root is not a directory")
        repo = args.repo.strip()
        if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", repo):
            return emit(False, mode="invalid", error="repository must be in owner/repo format")

        config = read_team_config(root)
        try:
            manul_config = json.loads(Path(args.manul_config).read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            return emit(False, mode="invalid", error=f"cannot read Manul configuration: {exc}")
        if not isinstance(manul_config, dict):
            return emit(False, mode="invalid", error="Manul configuration must be a JSON object")

        allowed = manul_config.get("agents", [])
        if not isinstance(allowed, list) or "orchestrator" not in allowed:
            return emit(False, mode="prerequisite", error="Manul role 'orchestrator' must be enabled in agents[]")
        role_file = Path(args.role_dir).expanduser() / "orchestrator.md"
        if not role_file.is_file():
            return emit(False, mode="prerequisite", error=f"required canonical agent definition is missing: {role_file}")
        skill = Path(args.skills_dir).expanduser() / "team-workflow" / "SKILL.md"
        if skill.is_symlink() or not skill.is_file():
            return emit(False, mode="prerequisite", error=f"required Team Workflow skill is missing: {skill}")

        trackers = resolve_trackers(config, manul_config)
        return emit(
            True,
            mode="team",
            repository=repo,
            route_agent="orchestrator",
            prApprovedByMan=config.get("prApprovedByMan", True),
            trackers=trackers,
            skill_path=str(skill),
        )
    except (OSError, UnicodeError, ValueError) as exc:
        return emit(False, mode="invalid", error=str(exc))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("inspect")
    check.add_argument("--repo-root", required=True)
    check.add_argument("--repo", required=True)
    check.add_argument("--manul-config", required=True)
    check.add_argument("--role-dir", default=str(Path.home() / ".agents/agents"))
    check.add_argument("--skills-dir", default=str(Path.home() / ".agents/skills"))
    check.set_defaults(func=inspect)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
