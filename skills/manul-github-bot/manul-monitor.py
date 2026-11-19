#!/usr/bin/env python3
"""Manul monitor registry and GitHub PR polling runtime."""
from __future__ import annotations
import argparse
import fcntl
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit

SCRIPT_DIR = Path(__file__).resolve().parent
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
REPO_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
ENV_RE = re.compile(r"\{env:([A-Za-z_][A-Za-z0-9_]*)\}")
OUTPUTS = {"log", "todo_local", "todo_remote"}
INTERVAL_DEFAULT = 300
INTERVAL_MIN = 60
INTERVAL_MAX = 86400
RUN_TIMEOUT = 240


class MonitorError(RuntimeError):
    pass


def now():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def paths():
    root = Path(os.environ.get("MANUL_DIR", str(Path.home() / ".manul"))).expanduser()
    state = Path(os.environ.get("MANUL_STATE_DIR", str(root / "state"))).expanduser()
    return {
        "root": root,
        "state": state,
        "locks": Path(os.environ.get("MANUL_LOCKS_DIR", str(state / "locks"))).expanduser(),
        "config": Path(os.environ.get("MANUL_CONFIG", str(root / "config.json"))).expanduser(),
        "db": Path(os.environ.get("MANUL_MONITORS_DB", str(state / "monitors.db"))).expanduser(),
        "monitors": Path(os.environ.get("MANUL_MONITORS_DIR", str(root / "monitors"))).expanduser(),
        "log": Path(os.environ.get("MANUL_MONITOR_LOG", str(root / "logs" / "monitor.log"))).expanduser(),
    }


def connect(p):
    p["db"].parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(p["db"], timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA busy_timeout=30000")
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript("""
    CREATE TABLE IF NOT EXISTS monitors(
      id TEXT PRIMARY KEY, name TEXT NOT NULL, config_path TEXT NOT NULL,
      status TEXT NOT NULL, enabled INTEGER NOT NULL, interval_seconds INTEGER NOT NULL,
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL, next_run_at TEXT,
      last_run_at TEXT, last_status TEXT, last_error TEXT
    );
    CREATE TABLE IF NOT EXISTS monitor_runs(
      id INTEGER PRIMARY KEY AUTOINCREMENT, monitor_id TEXT NOT NULL REFERENCES monitors(id),
      started_at TEXT NOT NULL, finished_at TEXT, status TEXT NOT NULL,
      events_found INTEGER NOT NULL DEFAULT 0, events_delivered INTEGER NOT NULL DEFAULT 0,
      error TEXT
    );
    CREATE TABLE IF NOT EXISTS monitor_events(
      monitor_id TEXT NOT NULL REFERENCES monitors(id), event_key TEXT NOT NULL,
      event_type TEXT NOT NULL, repository TEXT NOT NULL, event_created_at TEXT NOT NULL,
      payload_json TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending', last_error TEXT,
      received_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      PRIMARY KEY(monitor_id,event_key)
    );
    CREATE TABLE IF NOT EXISTS monitor_deliveries(
      monitor_id TEXT NOT NULL, event_key TEXT NOT NULL, output_key TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT, updated_at TEXT NOT NULL,
      PRIMARY KEY(monitor_id,event_key,output_key),
      FOREIGN KEY(monitor_id,event_key) REFERENCES monitor_events(monitor_id,event_key)
    );
    CREATE INDEX IF NOT EXISTS idx_monitors_due ON monitors(enabled,status,next_run_at);
    CREATE INDEX IF NOT EXISTS idx_monitor_events_pending ON monitor_events(monitor_id,status);
    """)
    return db


def load_json(path, description):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise MonitorError(f"Cannot read {description}: {exc}") from None
    if not isinstance(value, dict):
        raise MonitorError(f"{description} must be a JSON object")
    return value


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + f".tmp-{os.getpid()}")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(temp, path)


def validate(raw, manul):
    if not isinstance(raw, dict):
        raise MonitorError("Monitor definition must be a JSON object")
    mid = raw.get("id")
    name = raw.get("name")
    if not isinstance(mid, str) or not ID_RE.fullmatch(mid):
        raise MonitorError("id must contain lowercase letters, digits and hyphens (1-63 chars)")
    if not isinstance(name, str) or not name.strip() or len(name) > 120:
        raise MonitorError("name must be a non-empty string (max 120 chars)")
    enabled = raw.get("enabled", True)
    if not isinstance(enabled, bool):
        raise MonitorError("enabled must be a boolean")
    schedule = raw.get("schedule", {})
    if not isinstance(schedule, dict):
        raise MonitorError("schedule must be an object")
    interval = schedule.get("intervalSeconds", INTERVAL_DEFAULT)
    if isinstance(interval, bool) or not isinstance(interval, int) or not INTERVAL_MIN <= interval <= INTERVAL_MAX:
        raise MonitorError(f"schedule.intervalSeconds must be {INTERVAL_MIN}-{INTERVAL_MAX}")
    source = raw.get("source")
    if not isinstance(source, dict) or source.get("type") != "github_pull_requests":
        raise MonitorError("source.type must be github_pull_requests")
    allowed = manul.get("repositories", [])
    allowed = {r for r in allowed if isinstance(r, str) and REPO_RE.fullmatch(r)} if isinstance(allowed, list) else set()
    requested = source.get("repositories", "configured")
    if requested == "configured":
        repos = sorted(allowed)
    elif isinstance(requested, list) and requested and all(isinstance(r, str) and REPO_RE.fullmatch(r) for r in requested):
        repos = sorted(set(requested))
        if set(repos) - allowed:
            raise MonitorError("Monitor repositories must be included in Manul .repositories: " + ", ".join(sorted(set(repos) - allowed)))
    else:
        raise MonitorError("source.repositories must be 'configured' or a non-empty owner/repo array")
    if not repos:
        raise MonitorError("Manul .repositories is empty")
    filters = raw.get("filters", {})
    if not isinstance(filters, dict):
        raise MonitorError("filters must be an object")
    exclude_self = filters.get("excludeSelf", True)
    exclude_drafts = filters.get("excludeDrafts", True)
    if not isinstance(exclude_self, bool) or not isinstance(exclude_drafts, bool):
        raise MonitorError("filters.excludeSelf and filters.excludeDrafts must be booleans")
    sources = [s for s in manul.get("taskSources", []) if isinstance(s, dict) and s.get("enabled", True) is not False]
    outputs = raw.get("outputs")
    if not isinstance(outputs, list) or not outputs:
        raise MonitorError("outputs must be a non-empty array")
    normalized = []
    for item in outputs:
        kind = item if isinstance(item, str) else item.get("type") if isinstance(item, dict) else None
        if kind not in OUTPUTS:
            raise MonitorError("Supported output types: log, todo_local, todo_remote")
        if kind in [x["type"] for x in normalized]:
            continue
        provider = {"todo_local": "todo_local_mcp", "todo_remote": "todo_remote_mcp"}.get(kind)
        if provider and not any(s.get("type") == provider for s in sources):
            raise MonitorError(f"{kind} output requires an enabled {provider} taskSources entry")
        normalized.append({"type": kind})
    result = dict(raw)
    result.update({
        "version": 1,
        "enabled": enabled,
        "schedule": {"intervalSeconds": interval},
        "source": {"type": "github_pull_requests", "repositories": repos},
        "filters": {"excludeSelf": exclude_self, "excludeDrafts": exclude_drafts},
        "outputs": normalized,
    })
    return result


def monitor_dirs(p, mid):
    base = p["monitors"] / mid
    d = {"base": base, "config": base / "monitor.json", "workspace": base / "workspace",
         "logs": base / "logs", "runs": base / "runs", "lock": base / "monitor.lock"}
    for key in ("workspace", "logs", "runs"):
        d[key].mkdir(parents=True, exist_ok=True)
    return d


def get_row(db, mid):
    row = db.execute("SELECT * FROM monitors WHERE id=?", (mid,)).fetchone()
    if row is None:
        raise MonitorError(f"Monitor not found: {mid}")
    return row


def config_for(row):
    return load_json(row["config_path"], "monitor definition")


def load_input(filename):
    raw = sys.stdin.read() if filename in (None, "-") else Path(filename).expanduser().read_text(encoding="utf-8")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise MonitorError(f"Invalid monitor JSON: {exc}") from None
    if not isinstance(value, dict):
        raise MonitorError("Monitor definition must be a JSON object")
    return value


def create(args, p):
    manul = load_json(p["config"], "Manul config")
    cfg = validate(load_input(args.config), manul)
    d = monitor_dirs(p, cfg["id"])
    if d["config"].exists():
        raise MonitorError(f"Monitor workspace already exists: {d['base']}")
    stamp = now()
    write_json(d["config"], cfg)
    try:
        with connect(p) as db:
            db.execute(
                "INSERT INTO monitors(id,name,config_path,status,enabled,interval_seconds,created_at,updated_at,next_run_at) VALUES(?,?,?,?,?,?,?,?,?)",
                (cfg["id"], cfg["name"], str(d["config"]), "active" if cfg["enabled"] else "paused",
                 int(cfg["enabled"]), cfg["schedule"]["intervalSeconds"], stamp, stamp, stamp if cfg["enabled"] else None),
            )
    except sqlite3.IntegrityError:
        d["config"].unlink(missing_ok=True)
        raise MonitorError(f"Monitor already exists: {cfg['id']}") from None
    return {"id": cfg["id"], "status": "active" if cfg["enabled"] else "paused", "workspace": str(d["base"])}


def update(args, p):
    manul = load_json(p["config"], "Manul config")
    cfg = validate(load_input(args.config), manul)
    if cfg["id"] != args.monitor_id:
        raise MonitorError("Updated monitor id must match the existing id")
    stamp = now()
    with connect(p) as db:
        row = get_row(db, args.monitor_id)
        if row["status"] == "deleted":
            raise MonitorError("Deleted monitors cannot be updated")
        d = monitor_dirs(p, args.monitor_id)
        write_json(d["config"], cfg)
        enabled = int(row["status"] == "active" and cfg["enabled"])
        status = "active" if enabled else "paused"
        db.execute("UPDATE monitors SET name=?,interval_seconds=?,enabled=?,status=?,updated_at=?,next_run_at=? WHERE id=?",
                   (cfg["name"], cfg["schedule"]["intervalSeconds"], enabled, status, stamp, stamp if enabled else None, args.monitor_id))
    return {"id": args.monitor_id, "status": status, "workspace": str(d["base"])}


def listing(args, p):
    with connect(p) as db:
        sql = "SELECT * FROM monitors" + ("" if args.all else " WHERE status!='deleted'") + " ORDER BY created_at,id"
        rows = db.execute(sql).fetchall()
    return [{"id": r["id"], "name": r["name"], "status": r["status"], "enabled": bool(r["enabled"]),
             "intervalSeconds": r["interval_seconds"], "lastRunAt": r["last_run_at"],
             "lastStatus": r["last_status"], "lastError": r["last_error"], "nextRunAt": r["next_run_at"]} for r in rows]


def show(args, p):
    with connect(p) as db:
        row = get_row(db, args.monitor_id)
        runs = db.execute("SELECT * FROM monitor_runs WHERE monitor_id=? ORDER BY id DESC LIMIT 10", (args.monitor_id,)).fetchall()
        pending = db.execute("SELECT COUNT(*) FROM monitor_events WHERE monitor_id=? AND status!='delivered'", (args.monitor_id,)).fetchone()[0]
        cfg = config_for(row)
    d = monitor_dirs(p, args.monitor_id)
    return {"id": row["id"], "name": row["name"], "status": row["status"], "enabled": bool(row["enabled"]),
            "createdAt": row["created_at"], "updatedAt": row["updated_at"], "nextRunAt": row["next_run_at"],
            "lastRunAt": row["last_run_at"], "lastStatus": row["last_status"], "lastError": row["last_error"],
            "pendingEvents": pending, "config": cfg, "workspace": str(d["workspace"]), "logs": str(d["logs"]),
            "runs": [{"id": r["id"], "startedAt": r["started_at"], "finishedAt": r["finished_at"],
                      "status": r["status"], "eventsFound": r["events_found"], "eventsDelivered": r["events_delivered"],
                      "error": r["error"]} for r in runs]}


def set_status(args, p, status):
    stamp = now()
    with connect(p) as db:
        row = get_row(db, args.monitor_id)
        if row["status"] == "deleted":
            raise MonitorError("Deleted monitors cannot be changed")
        if status == "active" and config_for(row).get("enabled", True) is not True:
            raise MonitorError("Monitor definition has enabled=false; update it before resuming")
        enabled = int(status == "active")
        db.execute("UPDATE monitors SET status=?,enabled=?,updated_at=?,next_run_at=? WHERE id=?",
                   (status, enabled, stamp, stamp if enabled else None, args.monitor_id))
    return {"id": args.monitor_id, "status": status}


def delete(args, p):
    with connect(p) as db:
        get_row(db, args.monitor_id)
        db.execute("UPDATE monitors SET status='deleted',enabled=0,updated_at=?,next_run_at=NULL WHERE id=?", (now(), args.monitor_id))
    return {"id": args.monitor_id, "status": "deleted", "workspaceRetained": True}


def gh_login():
    proc = subprocess.run(["gh", "api", "user", "--jq", ".login"], text=True, capture_output=True, timeout=30)
    value = proc.stdout.strip()
    if proc.returncode or not value:
        raise MonitorError("Could not resolve authenticated GitHub user: " + (proc.stderr.strip()[:300] or "unknown error"))
    return value


def gh_prs(repo):
    proc = subprocess.run(["gh", "pr", "list", "--repo", repo, "--state", "open", "--limit", "1000",
                           "--json", "number,title,url,author,isDraft,createdAt"],
                          text=True, capture_output=True, timeout=90)
    if proc.returncode:
        raise MonitorError(f"{repo}: " + (proc.stderr.strip()[:300] or "GitHub query failed"))
    try:
        value = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        raise MonitorError(f"{repo}: invalid GitHub PR JSON") from None
    if not isinstance(value, list):
        raise MonitorError(f"{repo}: GitHub PR response is not an array")
    return [x for x in value if isinstance(x, dict)]


def event_key(event):
    return f"github:{event['repository']}:pull_request:{event['number']}:opened"


def discover(cfg, created_after, login):
    found, errors = [], []
    filters = cfg["filters"]
    for repo in cfg["source"]["repositories"]:
        try:
            prs = gh_prs(repo)
        except MonitorError as exc:
            errors.append(str(exc))
            continue
        for pr in prs:
            author_obj = pr.get("author") or {}
            author = author_obj.get("login", "") if isinstance(author_obj, dict) else str(author_obj)
            created = pr.get("createdAt") or ""
            number, url = pr.get("number"), pr.get("url")
            if not isinstance(number, int) or number < 1 or not isinstance(url, str) or not url or not created or created <= created_after:
                continue
            if filters["excludeSelf"] and author.casefold() == login.casefold():
                continue
            if filters["excludeDrafts"] and pr.get("isDraft") is True:
                continue
            found.append({"type": "github.pull_request.opened", "repository": repo, "number": number,
                          "title": pr.get("title") or f"Pull request #{number}", "url": url,
                          "author": author or "unknown", "createdAt": created, "isDraft": pr.get("isDraft") is True})
    return found, errors


def todo_config(p, provider):
    manul = load_json(p["config"], "Manul config")
    expected = "todo_local_mcp" if provider == "todo_local" else "todo_remote_mcp"
    matches = [s for s in manul.get("taskSources", []) if isinstance(s, dict) and s.get("type") == expected and s.get("enabled", True) is not False]
    if not matches:
        raise MonitorError(f"No enabled taskSources entry for {expected}")
    source = matches[0]
    url = source.get("url", "")
    if not isinstance(url, str) or not url:
        raise MonitorError(f"{expected} URL is missing")
    if provider == "todo_local":
        helper = SCRIPT_DIR / "todo-local-mcp-url.sh"
        proc = subprocess.run(["bash", "-c", 'source "$1"; todo_local_mcp_resolve_url "$2"',
                               "manul-monitor", str(helper), url], text=True, capture_output=True, timeout=10)
        if proc.returncode or not proc.stdout.strip():
            raise MonitorError("Todo Local MCP endpoint is unavailable")
        return proc.stdout.strip(), None
    def substitute(match):
        name = match.group(1)
        value = os.environ.get(name, "")
        if not value:
            raise MonitorError(f"Required environment variable is missing: {name}")
        return value
    url = ENV_RE.sub(substitute, url)
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.username or parsed.password or parsed.fragment:
        raise MonitorError("Todo Remote MCP URL must be HTTP(S) without embedded credentials or a fragment")
    token_env = source.get("tokenEnv")
    if not isinstance(token_env, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", token_env) or not os.environ.get(token_env):
        raise MonitorError("Todo Remote MCP tokenEnv is missing, invalid or empty")
    return url, token_env


def mcp_call(url, token_env, tool, arguments):
    client = SCRIPT_DIR / "todo-mcp-client.py"
    cmd = [sys.executable, str(client), "--url", url, "--tool", tool,
           "--arguments", json.dumps(arguments, ensure_ascii=False), "--timeout", "30"]
    if token_env:
        cmd.extend(["--token-env", token_env])
    proc = subprocess.run(cmd, text=True, capture_output=True, timeout=45)
    if proc.returncode:
        raise MonitorError(proc.stderr.strip()[:400] or f"Todo MCP {tool} failed")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        raise MonitorError("Todo MCP client returned invalid JSON") from None


def contains_marker(value, marker):
    if isinstance(value, list):
        return any(contains_marker(x, marker) for x in value)
    if isinstance(value, dict):
        if marker in str(value.get("description") or ""):
            return True
        return any(contains_marker(value.get(k), marker) for k in ("subTasks", "tasks", "items"))
    return False


def deliver(provider, event, mid, run_id, p):
    if provider == "log":
        d = monitor_dirs(p, mid)
        key = event_key(event)
        event_log = d["logs"] / "events.jsonl"
        # The file is the output's idempotency witness. A crash after append
        # but before the SQLite delivery update must not append the same event
        # again when the pending delivery is retried.
        if event_log.is_file():
            with event_log.open("r", encoding="utf-8") as stream:
                for line in stream:
                    try:
                        if json.loads(line).get("eventKey") == key:
                            return
                    except (json.JSONDecodeError, AttributeError):
                        continue
        record = {"monitorId": mid, "runId": run_id, "eventKey": key, "event": event, "recordedAt": now()}
        with event_log.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")
        return
    url, token = todo_config(p, provider)
    digest = hashlib.sha256(event_key(event).encode("utf-8")).hexdigest()
    marker = f"<!-- MANUL_MONITOR_EVENT:v1:{digest} -->"
    list_tool, create_tool = ("list_tasks", "create_task") if provider == "todo_local" else ("todo_list_tasks", "todo_create_task")
    current = mcp_call(url, token, list_tool, {})
    if contains_marker(current, marker):
        return
    description = (f"## Review PR #{event['number']} — {event['title']}\n\n"
                   f"Repository: `{event['repository']}`\n\nAuthor: @{event['author']}\n\n"
                   f"{event['url']}\n\nReview the pull request and record the findings.\n\n{marker}")
    if provider == "todo_local":
        args = {"description": description, "highestPriorityAsDefault": False}
    else:
        args = {"task": {"description": description, "highestPriorityAsDefault": False}}
    mcp_call(url, token, create_tool, args)
    verified = mcp_call(url, token, list_tool, {})
    if not contains_marker(verified, marker):
        raise MonitorError("Todo task was not readable after creation; delivery will retry")


def process_events(db, mid, cfg, run_id, p):
    events = db.execute("SELECT * FROM monitor_events WHERE monitor_id=? AND status!='delivered' ORDER BY event_created_at,event_key", (mid,)).fetchall()
    completed, errors = 0, []
    for row in events:
        event = json.loads(row["payload_json"])
        all_ok = True
        for output in cfg["outputs"]:
            kind = output["type"]
            stamp = now()
            with db:
                db.execute("INSERT OR IGNORE INTO monitor_deliveries(monitor_id,event_key,output_key,status,updated_at) VALUES(?,?,?,'pending',?)",
                           (mid, row["event_key"], kind, stamp))
            delivery = db.execute("SELECT * FROM monitor_deliveries WHERE monitor_id=? AND event_key=? AND output_key=?",
                                  (mid, row["event_key"], kind)).fetchone()
            if delivery["status"] == "delivered":
                continue
            try:
                deliver(kind, event, mid, run_id, p)
                with db:
                    db.execute("UPDATE monitor_deliveries SET status='delivered',attempts=attempts+1,last_error=NULL,updated_at=? WHERE monitor_id=? AND event_key=? AND output_key=?",
                               (now(), mid, row["event_key"], kind))
            except (MonitorError, OSError, subprocess.TimeoutExpired) as exc:
                all_ok = False
                detail = str(exc)[:500]
                errors.append(f"{row['event_key']} -> {kind}: {detail}")
                with db:
                    db.execute("UPDATE monitor_deliveries SET status='pending',attempts=attempts+1,last_error=?,updated_at=? WHERE monitor_id=? AND event_key=? AND output_key=?",
                               (detail, now(), mid, row["event_key"], kind))
        with db:
            if all_ok:
                db.execute("UPDATE monitor_events SET status='delivered',last_error=NULL,updated_at=? WHERE monitor_id=? AND event_key=?",
                           (now(), mid, row["event_key"]))
                completed += 1
            else:
                db.execute("UPDATE monitor_events SET status='pending',last_error=?,updated_at=? WHERE monitor_id=? AND event_key=?",
                           ("; ".join(errors[-3:])[:1000], now(), mid, row["event_key"]))
    return len(events), completed, errors


def run_monitor(mid, p):
    if not ID_RE.fullmatch(mid):
        raise MonitorError("Invalid monitor id")
    d = monitor_dirs(p, mid)
    with d["lock"].open("a+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"id": mid, "status": "skipped", "reason": "already_running"}
        with connect(p) as db:
            row = get_row(db, mid)
            if row["status"] != "active" or not row["enabled"]:
                return {"id": mid, "status": "skipped", "reason": row["status"]}
            started = now()
            run_cursor = db.execute("INSERT INTO monitor_runs(monitor_id,started_at,status) VALUES(?,?,'running')", (mid, started))
            run_id = run_cursor.lastrowid
            errors, inserted, delivered_count = [], 0, 0
            try:
                cfg = config_for(row)
                login = gh_login() if cfg["filters"]["excludeSelf"] else ""
                discovered, scan_errors = discover(cfg, row["created_at"], login)
                errors.extend(scan_errors)
                for event in discovered:
                    stamp = now()
                    with db:
                        cur = db.execute("INSERT OR IGNORE INTO monitor_events(monitor_id,event_key,event_type,repository,event_created_at,payload_json,status,received_at,updated_at) VALUES(?,?,?,?,?,?,'pending',?,?)",
                                         (mid, event_key(event), event["type"], event["repository"], event["createdAt"],
                                          json.dumps(event, ensure_ascii=False), stamp, stamp))
                    inserted += cur.rowcount
                pending, delivered_count, delivery_errors = process_events(db, mid, cfg, run_id, p)
                errors.extend(delivery_errors)
                status = "partial" if errors else "completed"
            except Exception as exc:
                pending, status = 0, "failed"
                errors.append(str(exc)[:1000])
            finished = now()
            detail = "\n".join(errors)[:2000] or None
            with db:
                db.execute("UPDATE monitor_runs SET finished_at=?,status=?,events_found=?,events_delivered=?,error=? WHERE id=?",
                           (finished, status, inserted, delivered_count, detail, run_id))
                db.execute("UPDATE monitors SET last_run_at=?,last_status=?,last_error=?,updated_at=? WHERE id=?",
                           (finished, status, detail, finished, mid))
            doc = {"runId": run_id, "monitorId": mid, "startedAt": started, "finishedAt": finished,
                   "status": status, "eventsFound": inserted, "pendingEventsSeen": pending,
                   "eventsDelivered": delivered_count, "errors": errors}
            write_json(d["runs"] / f"run-{run_id}.json", doc)
            if status == "failed":
                raise MonitorError(detail or "Monitor run failed")
            return doc


def tick(p):
    if not p["db"].is_file():
        return {"status": "idle", "due": 0}
    p["locks"].mkdir(parents=True, exist_ok=True)
    with (p["locks"] / "monitors-tick.lock").open("a+") as lock:
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {"status": "skipped", "reason": "tick_already_running"}
        stamp = now()
        with connect(p) as db:
            due = db.execute("SELECT * FROM monitors WHERE enabled=1 AND status='active' AND next_run_at<=? ORDER BY next_run_at,id", (stamp,)).fetchall()
            reservations = []
            for row in due:
                next_at = (datetime.now(timezone.utc) + timedelta(seconds=row["interval_seconds"])).replace(microsecond=0).isoformat().replace("+00:00", "Z")
                with db:
                    cur = db.execute("UPDATE monitors SET next_run_at=?,updated_at=? WHERE id=? AND enabled=1 AND status='active' AND next_run_at<=?",
                                     (next_at, stamp, row["id"], stamp))
                if cur.rowcount:
                    reservations.append(row["id"])
        outcomes = []
        for mid in reservations:
            d = monitor_dirs(p, mid)
            runner_log = (d["logs"] / "runner.log").open("a", encoding="utf-8")
            try:
                proc = subprocess.Popen(
                    [sys.executable, str(Path(__file__).resolve()), "run", mid, "--json"],
                    stdin=subprocess.DEVNULL, stdout=runner_log, stderr=runner_log,
                    start_new_session=True, close_fds=True,
                )
                outcomes.append({"id": mid, "status": "started", "pid": proc.pid})
                log(p, f"started monitor process id={mid} pid={proc.pid}")
            except OSError as exc:
                detail = str(exc)[:300]
                outcomes.append({"id": mid, "status": "failed_to_start", "error": detail})
                with connect(p) as db:
                    db.execute("UPDATE monitors SET next_run_at=?,last_status='failed_to_start',last_error=?,updated_at=? WHERE id=? AND status='active'",
                               (now(), detail, now(), mid))
                log(p, f"could not start monitor {mid}: {detail}")
            finally:
                runner_log.close()
        return {"status": "scheduled", "due": len(reservations), "runs": outcomes}


def log(p, message):
    line = f"[{now()}] {message}"
    try:
        p["log"].parent.mkdir(parents=True, exist_ok=True)
        with p["log"].open("a", encoding="utf-8") as stream:
            stream.write(line + "\n")
    except OSError:
        pass
    print(line, file=sys.stderr)


def render(value, as_json):
    if as_json:
        print(json.dumps(value, ensure_ascii=False, indent=2))
    elif isinstance(value, list):
        if not value:
            print("No monitors found")
        else:
            print(f"{'ID':<32} {'STATUS':<9} {'INTERVAL':>8}  NAME")
            for row in value:
                print(f"{row['id']:<32} {row['status']:<9} {row['intervalSeconds']:>5}s  {row['name']}")
    elif isinstance(value, dict):
        for key, item in value.items():
            print(f"{key}: {json.dumps(item, ensure_ascii=False) if isinstance(item, (dict, list)) else item}")
    else:
        print(value)


def parser():
    root = argparse.ArgumentParser(prog="manul-monitor", description="Manage independent Manul monitors.")
    sub = root.add_subparsers(dest="command", required=True)
    for name in ("create", "update"):
        cmd = sub.add_parser(name)
        if name == "update":
            cmd.add_argument("monitor_id")
        cmd.add_argument("--config", help="JSON file; use - or omit to read stdin")
        cmd.add_argument("--json", action="store_true")
    cmd = sub.add_parser("list")
    cmd.add_argument("--all", action="store_true")
    cmd.add_argument("--json", action="store_true")
    for name in ("show", "pause", "resume", "delete", "run"):
        cmd = sub.add_parser(name)
        cmd.add_argument("monitor_id")
        cmd.add_argument("--json", action="store_true")
    cmd = sub.add_parser("tick", help=argparse.SUPPRESS)
    cmd.add_argument("--json", action="store_true")
    return root


def main():
    args = parser().parse_args()
    p = paths()
    try:
        if args.command == "create":
            result = create(args, p)
        elif args.command == "update":
            result = update(args, p)
        elif args.command == "list":
            result = listing(args, p)
        elif args.command == "show":
            result = show(args, p)
        elif args.command == "pause":
            result = set_status(args, p, "paused")
        elif args.command == "resume":
            result = set_status(args, p, "active")
        elif args.command == "delete":
            result = delete(args, p)
        elif args.command == "run":
            result = run_monitor(args.monitor_id, p)
        else:
            result = tick(p)
        render(result, getattr(args, "json", False))
        return 0
    except (MonitorError, OSError, sqlite3.Error, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
