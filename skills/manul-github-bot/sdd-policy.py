#!/usr/bin/env python3
"""Fail-closed repository policy inspection for Manul SDD routing."""
from __future__ import annotations
import argparse, json, os, re, shutil, subprocess
from pathlib import Path

def emit(ok: bool, **values: object) -> int:
    print(json.dumps({"ok": ok, **values}, ensure_ascii=False, sort_keys=True))
    return 0 if ok else 2

def scalar(value: str) -> str:
    value=value.strip()
    if len(value)>=2 and value[0]==value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value

def read_config(path: Path) -> tuple[bool,str]:
    if not path.exists():
        return False,"missing"
    if path.is_symlink() or not path.is_file():
        raise ValueError("config must be a regular repository file")
    values={}
    section=None
    for number,raw in enumerate(path.read_text(encoding="utf-8").splitlines(),1):
        line=raw.split("#",1)[0].rstrip()
        if not line.strip():
            continue
        indent=len(line)-len(line.lstrip())
        match=re.fullmatch(r"([A-Za-z_][A-Za-z0-9_-]*):(?:\s*(.*))?",line.strip())
        if not match:
            raise ValueError(f"unsupported YAML syntax at line {number}")
        key,value=match.group(1),match.group(2) or ""
        if indent==0:
            if key in values:
                raise ValueError(f"duplicate top-level key: {key}")
            if key not in {"version","mode","specification","policy"}:
                raise ValueError(f"unsupported top-level key: {key}")
            if key in {"specification","policy"}:
                if value:
                    raise ValueError(f"{key} must be a YAML mapping")
                section=key
                continue
            section=None
            values[key]=scalar(value)
        elif section not in {"specification","policy"}:
            raise ValueError(f"unexpected nested key at line {number}")
    if values.get("version")!="1":
        raise ValueError("unsupported or missing SDD config version (expected 1)")
    if values.get("mode")!="specification-driven":
        raise ValueError("unsupported or missing mode (expected specification-driven)")
    return True,"specification-driven"

def opencode_binary():
    options=[os.environ.get("OPENCODE_BIN",""),shutil.which("opencode") or "",
             str(Path.home()/".opencode/bin/opencode"),str(Path.home()/".local/bin/opencode"),
             "/usr/local/bin/opencode","/usr/bin/opencode"]
    return next((p for p in options if p and Path(p).is_file() and os.access(p,os.X_OK)),None)

def probe_opencode_agent(binary, role, root):
    """Return (status, detail) using OpenCode V2 discovery, with a V1 fallback.

    OpenCode V2 exposes the complete native-agent catalog as JSON through
    `debug agents`. V1 used the singular `debug agent <name>` command.
    A successful V2 response is authoritative: a missing ID is not retried
    through the legacy command.
    """
    try:
        result = subprocess.run(
            [binary, "debug", "agents"],
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "error", "OpenCode V2 agent discovery command could not be completed"

    if result.returncode == 0:
        try:
            agents = json.loads(result.stdout)
        except json.JSONDecodeError:
            return "error", "OpenCode debug agents returned invalid JSON"
        if not isinstance(agents, list) or any(
            not isinstance(agent, dict) or not isinstance(agent.get("id"), str)
            for agent in agents
        ):
            return "error", "OpenCode debug agents returned an unexpected JSON structure"
        if any(agent["id"] == role for agent in agents):
            return "found", ""
        return "missing", f"native OpenCode agent '{role}' is not listed by OpenCode"

    command_error = f"{result.stdout}\n{result.stderr}".lower()
    if not re.search(
        r"unknown (?:subcommand|command)|no command named|unrecognized command",
        command_error,
    ):
        return "error", f"OpenCode debug agents failed with exit code {result.returncode}"

    # OpenCode V1 compatibility: its singular command is the only discovery
    # interface available there. Do not use it to second-guess a valid V2 list.
    try:
        legacy = subprocess.run(
            [binary, "debug", "agent", role],
            cwd=root,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "error", "OpenCode V1 agent discovery command could not be completed"
    if legacy.returncode == 0:
        return "found", ""
    return "error", f"OpenCode V1 agent discovery failed with exit code {legacy.returncode}"


def require_role(role,role_dir,runtime,root):
    role_file=role_dir/(role+".md")
    if role_file.is_symlink() or not role_file.is_file() or not os.access(role_file,os.R_OK):
        return f"required canonical agent definition is missing: {role_file}"
    if runtime=="opencode":
        binary=opencode_binary()
        if not binary:
            return "OpenCode runtime is selected but its CLI cannot be resolved"
        status, detail = probe_opencode_agent(binary, role, root)
        if status == "missing":
            return detail
        if status != "found":
            return f"could not verify native OpenCode agent '{role}': {detail}"
    return None

def inspect(args):
    root=Path(args.repo_root).resolve(strict=True)
    agent_dir=Path(args.role_dir).expanduser()
    skills_dir=Path(args.skills_dir).expanduser()
    prompt=args.prompt.strip()
    first=prompt.split(maxsplit=1)[0].lower() if prompt else ""
    bootstrap=args.action=="IMPLEMENT" and args.agent=="sdd" and first=="bootstrap"
    if args.action not in {"IMPLEMENT","REVIEW_FIX"}:
        return emit(True,mode="standard",route_agent=args.agent,reason="non-implementation task")
    spec_dir=root/".specification"
    if spec_dir.is_symlink():
        return emit(False,mode="invalid",error="Invalid SDD configuration: .specification directory must not be a symlink")
    if spec_dir.exists() and not spec_dir.is_dir():
        return emit(False,mode="invalid",error="Invalid SDD configuration: .specification must be a directory")
    try:
        initialized,mode=read_config(spec_dir/"config.yaml")
    except (OSError,UnicodeError,ValueError) as exc:
        return emit(False,mode="invalid",error=f"Invalid SDD configuration: {exc}")
    if not initialized:
        if args.agent!="sdd":
            return emit(True,mode="standard",route_agent=args.agent,reason="no SDD config")
        if not bootstrap:
            return emit(False,mode="missing",error="SDD is not initialized. No files were changed. Run /manul sdd bootstrap explicitly.")
        try:
            manul_config=json.loads(Path(args.manul_config).read_text(encoding="utf-8"))
        except (OSError,UnicodeError,json.JSONDecodeError) as exc:
            return emit(False,mode="bootstrap",error=f"Cannot read Manul role configuration: {exc}")
        allowed=manul_config.get("agents",[])
        if not isinstance(allowed,list):
            return emit(False,mode="bootstrap",error="Manul agents configuration is not an array")
        for role in ("sdd","orchestrator"):
            if role not in allowed:
                return emit(False,mode="bootstrap",error=f"Manul role '{role}' is not enabled in config.json agents[]; update Manul configuration")
            error=require_role(role,agent_dir,args.runtime,root)
            if error:
                return emit(False,mode="bootstrap",error=f"SDD prerequisite missing: {error}")
        skill=skills_dir/"specification-driven-development"/"SKILL.md"
        if skill.is_symlink() or not skill.is_file() or not os.access(skill,os.R_OK):
            return emit(False,mode="bootstrap",error=f"Required SDD skill is missing: {skill}")
        return emit(True,mode="bootstrap",route_agent="sdd",skill_path=str(skill))
    if bootstrap:
        return emit(False,mode=mode,error="SDD is already initialized. Use /manul sdd <request>; bootstrap cannot overwrite the active baseline.")
    try:
        manul_config=json.loads(Path(args.manul_config).read_text(encoding="utf-8"))
    except (OSError,UnicodeError,json.JSONDecodeError) as exc:
        return emit(False,mode=mode,error=f"Cannot read Manul role configuration: {exc}")
    allowed=manul_config.get("agents",[])
    if not isinstance(allowed,list):
        return emit(False,mode=mode,error="Manul agents configuration is not an array")
    for role in ("orchestrator","sdd"):
        if role not in allowed:
            return emit(False,mode=mode,error=f"Manul role '{role}' is not enabled in config.json agents[]; update Manul configuration")
        error=require_role(role,agent_dir,args.runtime,root)
        if error:
            return emit(False,mode=mode,error=f"SDD prerequisite missing: {error}")
    skill=skills_dir/"specification-driven-development"/"SKILL.md"
    if skill.is_symlink() or not skill.is_file() or not os.access(skill,os.R_OK):
        return emit(False,mode=mode,error=f"Required SDD skill is missing: {skill}")
    if args.agent not in {"","main","orchestrator","sdd"}:
        return emit(False,mode=mode,error=f"Direct role '{args.agent}' cannot bypass SDD. Use an ordinary /manul request or /manul sdd <request>.")
    return emit(True,mode=mode,route_agent=("sdd" if args.agent=="sdd" else "orchestrator"),skill_path=str(skill))

def main():
    parser=argparse.ArgumentParser()
    subs=parser.add_subparsers(dest="command",required=True)
    check=subs.add_parser("inspect")
    check.add_argument("--repo-root",required=True)
    check.add_argument("--agent",default="")
    check.add_argument("--prompt",default="")
    check.add_argument("--action",default="IMPLEMENT")
    check.add_argument("--runtime",default="openclaw")
    check.add_argument("--manul-config",required=True)
    check.add_argument("--role-dir",default=str(Path.home()/".agents/agents"))
    check.add_argument("--skills-dir",default=str(Path.home()/".agents/skills"))
    check.set_defaults(func=inspect)
    args=parser.parse_args()
    return args.func(args)

if __name__=="__main__":
    raise SystemExit(main())
