#!/usr/bin/env python3
"""Fail-closed repository policy inspection for Manul SDD routing."""
from __future__ import annotations
import argparse, json, math, os, re, shutil, subprocess, sys, time
from pathlib import Path
from typing import Callable, TypeVar

T = TypeVar("T", int, float)

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

def _run_debug_agents(binary, root, timeout: int) -> tuple[int | None, str, str, float]:
    """Run `opencode debug agents` and return (exit_code, stdout, stderr, duration)."""
    start = time.monotonic()
    try:
        result = subprocess.run(
            [binary, "debug", "agents"],
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        duration = time.monotonic() - start
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        # TimeoutExpired may expose captured output as bytes even with text=True.
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        return None, stdout, stderr, duration
    except OSError as exc:
        duration = time.monotonic() - start
        return 1, "", str(exc), duration
    duration = time.monotonic() - start
    return result.returncode, result.stdout, result.stderr, duration


def _parse_agent_list(stdout: str) -> tuple[str, list[dict[str, object]] | str]:
    """Parse JSON agent list. Returns (status, detail)."""
    try:
        agents = json.loads(stdout)
    except json.JSONDecodeError:
        return "error", "OpenCode debug agents returned invalid JSON"
    if not isinstance(agents, list) or any(
        not isinstance(agent, dict) or not isinstance(agent.get("id"), str)
        for agent in agents
    ):
        return "error", "OpenCode debug agents returned an unexpected JSON structure"
    return "ok", agents


def _classify_v2_error(stdout: str, stderr: str) -> bool:
    """Return True if error indicates V2 plural command is unsupported (V1 fallback applies)."""
    combined = f"{stdout}\n{stderr}".lower()
    return bool(re.search(
        r"unknown (?:subcommand|command)|no command named|unrecognized command",
        combined,
    ))


def _run_v1_probe(binary, role, root, timeout: int) -> tuple[str, str, float]:
    """Run V1 singular `debug agent <role>`. Returns (status, detail, duration)."""
    start = time.monotonic()
    try:
        legacy = subprocess.run(
            [binary, "debug", "agent", role],
            cwd=root,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        duration = time.monotonic() - start
        return "error", f"OpenCode V1 agent discovery timed out after {timeout}s", duration
    except OSError as exc:
        duration = time.monotonic() - start
        return "error", f"OpenCode V1 agent discovery failed: {exc}", duration
    duration = time.monotonic() - start
    if legacy.returncode == 0:
        return "found", "", duration
    return "error", f"OpenCode V1 agent discovery failed with exit code {legacy.returncode}", duration


def _retry_params() -> tuple[int, int, int, float]:
    """Retry/timeout schedule. Defaults are production values; environment
    overrides exist only so the test suite can exercise the same logic with
    short budgets. ``SDD_DISCOVERY_ATTEMPTS``, ``SDD_DISCOVERY_BASE_TIMEOUT``,
    ``SDD_DISCOVERY_MAX_TIMEOUT`` (seconds) and ``SDD_DISCOVERY_BACKOFF``
    (seconds) are read at call time.

    Invalid, non-numeric, or non-positive values fall back to defaults.
    """
    def _env(name: str, cast: Callable[[str], T], default: T) -> T:
        raw = os.environ.get(name, "").strip()
        if not raw:
            return default
        try:
            value = cast(raw)
        except (ValueError, OverflowError):
            return default
        # Reject zero/negative values and non-finite floats (nan/inf).
        if value <= 0 or (isinstance(value, float) and not math.isfinite(value)):
            return default
        return value
    return (
        _env("SDD_DISCOVERY_ATTEMPTS", int, 3),
        _env("SDD_DISCOVERY_BASE_TIMEOUT", int, 15),
        _env("SDD_DISCOVERY_MAX_TIMEOUT", int, 60),
        _env("SDD_DISCOVERY_BACKOFF", float, 0.5),
    )


def _timeout_for_attempt(attempt: int, base_timeout: int, max_timeout: int) -> int:
    """Per-attempt timeout: 15s, 30s, 60s (capped at max_timeout).

    Linear growth capped at max_timeout is intentional: the third attempt
    must reach the full budget, not 45s. ``attempt`` is 1-based; values
    outside the schedule clamp to the nearest bound.
    """
    # Treat inputs defensively even though _retry_params() already validates
    # environment values. The configured maximum is a hard upper bound for
    # every attempt, including the first one when base_timeout > max_timeout.
    base = max(1, base_timeout)
    maximum = max(1, max_timeout)
    schedule = (min(base, maximum), min(base * 2, maximum), maximum)
    index = max(0, min(attempt - 1, len(schedule) - 1))
    return schedule[index]


def probe_opencode_agent(binary, role, root):
    """Return (status, detail) using OpenCode V2 discovery with retry, V1 fallback.

    OpenCode V2 exposes the complete native-agent catalog as JSON through
    `debug agents`. V1 used the singular `debug agent <name>` command.
    A successful V2 response is authoritative: a missing ID is not retried
    through the legacy command.
    """
    max_attempts, base_timeout, max_timeout, backoff_base = _retry_params()

    last_error_detail = ""
    last_error_category = ""

    for attempt in range(1, max_attempts + 1):
        timeout = _timeout_for_attempt(attempt, base_timeout, max_timeout)
        exit_code, stdout, stderr, duration = _run_debug_agents(binary, root, timeout)

        stdout_len = len(stdout.encode("utf-8", errors="replace"))
        stderr_len = len(stderr.encode("utf-8", errors="replace"))
        exit_code_label = "timeout" if exit_code is None else str(exit_code)
        # Log discovery attempt details
        sys.stderr.write(
            f"[SDD-POLICY] discovery role={role} attempt={attempt}/{max_attempts} "
            f"exit_code={exit_code_label} duration={duration:.3f}s stdout_bytes={stdout_len} stderr_bytes={stderr_len}\n"
        )

        if exit_code == 0:
            status, agents = _parse_agent_list(stdout)
            if status == "ok":
                # Check for the requested role
                if any(agent["id"] == role for agent in agents):
                    return "found", ""
                # Valid list but role missing — authoritative, no retry
                return "missing", f"native OpenCode agent '{role}' is not listed by OpenCode"
            # status == "error" — invalid JSON/structure
            last_error_detail = agents  # contains error message
            last_error_category = "invalid_json"
            sys.stderr.write(f"[SDD-POLICY] discovery role={role} attempt={attempt} parse_error={agents}\n")
            # Retry on parse error (transient I/O)
        else:
            # Non-zero exit code
            if exit_code is None:
                # Timeout is not a CLI incompatibility and must never trigger V1 fallback.
                last_error_detail = f"OpenCode debug agents timed out after {timeout}s"
                last_error_category = "timeout"
                sys.stderr.write(f"[SDD-POLICY] discovery role={role} attempt={attempt} timeout after {timeout}s\n")
            elif _classify_v2_error(stdout, stderr):
                # V2 unsupported — try V1 fallback once.
                sys.stderr.write(f"[SDD-POLICY] discovery role={role} V2 unsupported, trying V1 fallback\n")
                v1_status, v1_detail, v1_duration = _run_v1_probe(binary, role, root, timeout)
                sys.stderr.write(
                    f"[SDD-POLICY] V1 fallback role={role} status={v1_status} duration={v1_duration:.3f}s\n"
                )
                return v1_status, v1_detail
            else:
                # Other V2 runtime errors are retried but never treated as V1 support.
                last_error_detail = f"OpenCode debug agents failed with exit code {exit_code}"
                last_error_category = "runtime_error"
                sys.stderr.write(f"[SDD-POLICY] discovery role={role} attempt={attempt} runtime_error exit_code={exit_code}\n")

        # Backoff before retry (except on last attempt)
        if attempt < max_attempts:
            sleep_time = backoff_base * (2 ** (attempt - 1))  # 0.5, 1.0
            time.sleep(sleep_time)

    # All retries exhausted
    return "error", f"could not verify native OpenCode agent '{role}': {last_error_detail} (category: {last_error_category})"


def discover_all_agents(binary, root):
    """Run a single discovery with retry and return (status, agents_list_or_error_detail)."""
    max_attempts, base_timeout, max_timeout, backoff_base = _retry_params()

    last_error_detail = ""
    last_error_category = ""

    for attempt in range(1, max_attempts + 1):
        timeout = _timeout_for_attempt(attempt, base_timeout, max_timeout)
        exit_code, stdout, stderr, duration = _run_debug_agents(binary, root, timeout)

        stdout_len = len(stdout.encode("utf-8", errors="replace"))
        stderr_len = len(stderr.encode("utf-8", errors="replace"))
        exit_code_label = "timeout" if exit_code is None else str(exit_code)
        sys.stderr.write(
            f"[SDD-POLICY] discovery_all attempt={attempt}/{max_attempts} "
            f"exit_code={exit_code_label} duration={duration:.3f}s stdout_bytes={stdout_len} stderr_bytes={stderr_len}\n"
        )

        if exit_code == 0:
            status, agents = _parse_agent_list(stdout)
            if status == "ok":
                return "ok", agents
            last_error_detail = agents
            last_error_category = "invalid_json"
            sys.stderr.write(f"[SDD-POLICY] discovery_all attempt={attempt} parse_error={agents}\n")
        else:
            if exit_code is None:
                last_error_detail = f"OpenCode debug agents timed out after {timeout}s"
                last_error_category = "timeout"
                sys.stderr.write(f"[SDD-POLICY] discovery_all attempt={attempt} timeout after {timeout}s\n")
            elif _classify_v2_error(stdout, stderr):
                # V2 unsupported — signal to caller that V1 fallback is needed per-role.
                return "v1_fallback", None
            else:
                last_error_detail = f"OpenCode debug agents failed with exit code {exit_code}"
                last_error_category = "runtime_error"
                sys.stderr.write(f"[SDD-POLICY] discovery_all attempt={attempt} runtime_error exit_code={exit_code}\n")

        if attempt < max_attempts:
            sleep_time = backoff_base * (2 ** (attempt - 1))
            time.sleep(sleep_time)

    return "error", f"could not discover OpenCode agents: {last_error_detail} (category: {last_error_category})"


def require_role(role, role_dir, runtime, root, discovery=None):
    """Check that a canonical role is available for the selected runtime.

    ``discovery`` is the single shared result of ``discover_all_agents``:
    ``(status, data)`` where status is ``ok`` (data is the parsed agent
    list), ``v1_fallback`` (V2 plural command unsupported; the V1 singular
    probe decides per role) or ``error`` (diagnostic failure after retries).
    When it is ``None`` the legacy per-role probe is used directly.
    """
    role_file=role_dir/(role+".md")
    if role_file.is_symlink() or not role_file.is_file() or not os.access(role_file,os.R_OK):
        return f"required canonical agent definition is missing: {role_file}"
    if runtime!="opencode":
        return None
    binary=opencode_binary()
    if not binary:
        return "OpenCode runtime is selected but its CLI cannot be resolved"
    if discovery is not None:
        status,data=discovery
        if status=="ok":
            # One authoritative V2 listing: a missing ID is a genuine missing
            # agent, never a transient discovery failure.
            if any(agent["id"] == role for agent in data):
                return None
            return f"native OpenCode agent '{role}' is not listed by OpenCode"
        if status=="v1_fallback":
            v1_status,v1_detail,_=_run_v1_probe(binary,role,root,15)
            if v1_status=="found":
                return None
            return f"could not verify native OpenCode agent '{role}': {v1_detail}"
        # status == "error": fail closed on the diagnostic failure itself.
        return f"could not verify native OpenCode agent '{role}': {data}"
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
        # One shared discovery run serves both roles: a single `debug agents`
        # invocation (with retry) instead of one probe per role.
        discovery=None
        if args.runtime=="opencode":
            binary=opencode_binary()
            if binary:
                discovery=discover_all_agents(binary,root)
        for role in ("sdd","orchestrator"):
            if role not in allowed:
                return emit(False,mode="bootstrap",error=f"Manul role '{role}' is not enabled in config.json agents[]; update Manul configuration")
            error=require_role(role,agent_dir,args.runtime,root,discovery)
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
    discovery=None
    if args.runtime=="opencode":
        binary=opencode_binary()
        if binary:
            discovery=discover_all_agents(binary,root)
    for role in ("orchestrator","sdd"):
        if role not in allowed:
            return emit(False,mode=mode,error=f"Manul role '{role}' is not enabled in config.json agents[]; update Manul configuration")
        error=require_role(role,agent_dir,args.runtime,root,discovery)
        if error:
            return emit(False,mode=mode,error=f"SDD prerequisite missing: {error}")
    skill=skills_dir/"specification-driven-development"/"SKILL.md"
    if skill.is_symlink() or not skill.is_file() or not os.access(skill,os.R_OK):
        return emit(False,mode=mode,error=f"Required SDD skill is missing: {skill}")
    if args.agent not in {"","main","orchestrator","sdd"}:
        return emit(False,mode=mode,error=f"Direct role '{args.agent}' cannot bypass SDD. Use an ordinary /manul request or /manul sdd <request>.")
    return emit(True,mode=mode,route_agent=("sdd" if args.agent=="sdd" else "orchestrator"),skill_path=str(skill))

def main(argv=None):
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
    args=parser.parse_args(argv)
    return args.func(args)

if __name__=="__main__":
    raise SystemExit(main())
