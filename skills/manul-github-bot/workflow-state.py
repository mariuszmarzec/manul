#!/usr/bin/env python3
"""Persistent, runtime-neutral workflow checkpoints stored in Manul SQLite."""
from __future__ import annotations
import argparse,hashlib,json,os,re,sqlite3,sys
from datetime import datetime,timezone
from pathlib import Path

BEGIN="MANUL_WORKFLOW_STATE_BEGIN"
END="MANUL_WORKFLOW_STATE_END"
IDENTIFIER=re.compile(r"^[A-Za-z0-9][A-Za-z0-9:._/-]{0,159}$")
SLUG=re.compile(r"^[a-z][a-z0-9_-]{0,63}$")

def connect(path):
    target=Path(path)
    target.parent.mkdir(parents=True,exist_ok=True)
    db=sqlite3.connect(str(target),timeout=5)
    db.row_factory=sqlite3.Row
    db.execute("PRAGMA busy_timeout=5000")
    db.executescript("""
    CREATE TABLE IF NOT EXISTS workflow_instances(
      workflowId TEXT PRIMARY KEY, workflowType TEXT NOT NULL, repository TEXT NOT NULL,
      sourceTaskId TEXT, conversationId TEXT, phase TEXT NOT NULL, status TEXT NOT NULL,
      stateJson TEXT NOT NULL, version INTEGER NOT NULL DEFAULT 1, createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS workflow_events(
      id INTEGER PRIMARY KEY AUTOINCREMENT, workflowId TEXT NOT NULL, eventKey TEXT NOT NULL UNIQUE,
      workflowType TEXT NOT NULL, repository TEXT NOT NULL, taskId TEXT, conversationId TEXT,
      phase TEXT NOT NULL, status TEXT NOT NULL, payloadJson TEXT NOT NULL, createdAt TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_workflow_events_workflow ON workflow_events(workflowId,id);
    CREATE INDEX IF NOT EXISTS idx_workflow_instances_repo ON workflow_instances(repository,updatedAt);
    """)
    return db

def redact(value):
    sensitive=re.compile(r"(token|secret|password|credential|api.?key|authorization)",re.I)
    if isinstance(value,dict):
        return {k:("[REDACTED]" if sensitive.search(str(k)) else redact(v)) for k,v in value.items()}
    if isinstance(value,list):
        return [redact(v) for v in value]
    return value

def validate(raw,repo):
    if not isinstance(raw,dict):
        raise ValueError("workflow state must be a JSON object")
    wid,wtype=raw.get("workflowId"),raw.get("workflowType")
    phase,status=raw.get("phase"),raw.get("status")
    declared_repo,data=raw.get("repository",repo),raw.get("data",{})
    for name,value in (("workflowId",wid),("repository",declared_repo)):
        if not isinstance(value,str) or not IDENTIFIER.fullmatch(value):
            raise ValueError(f"invalid {name}")
    for name,value in (("workflowType",wtype),("phase",phase),("status",status)):
        if not isinstance(value,str) or not SLUG.fullmatch(value):
            raise ValueError(f"invalid {name}")
    if declared_repo!=repo:
        raise ValueError("workflow repository does not match trusted task repository")
    if not isinstance(data,dict):
        raise ValueError("workflow data must be an object")
    return {"workflowId":wid,"workflowType":wtype,"repository":repo,"phase":phase,"status":status,"data":redact(data)}

def preserve_team_coordinator_state(db,event):
    if event.get("workflowType") != "team":
        return
    row=db.execute(
        "SELECT stateJson FROM workflow_instances WHERE workflowId=?",
        (event["workflowId"],)
    ).fetchone()
    if row is None:
        return
    try:
        previous=json.loads(row["stateJson"])
    except (TypeError,json.JSONDecodeError) as exc:
        raise ValueError("existing Team checkpoint is invalid; refusing to discard coordinator state") from exc

    previous_data=previous.get("data",{})
    new_data=event.get("data",{})
    if not isinstance(previous_data,dict) or not isinstance(new_data,dict):
        raise ValueError("Team checkpoint data must remain an object")

    previous_coordinator=previous_data.get("coordinator")
    new_coordinator=new_data.get("coordinator")
    if isinstance(previous_coordinator,dict):
        submitted=new_coordinator if isinstance(new_coordinator,dict) else {}
        merged=dict(submitted)
        # These fields are coordinator-owned. Only the parent may explicitly
        # acknowledge pending events by submitting pendingChildEvents: [].
        for key,value in previous_coordinator.items():
            if key != "pendingChildEvents" or "pendingChildEvents" not in submitted:
                merged[key]=value
        new_data["coordinator"]=merged

    previous_items=previous_data.get("items",[])
    new_items=new_data.get("items",[])
    if isinstance(previous_items,list) and isinstance(new_items,list):
        dispatched_keys={
            item.get("id"):item.get("lastDispatchedEventKey")
            for item in previous_items
            if isinstance(item,dict)
            and isinstance(item.get("id"),str)
            and isinstance(item.get("lastDispatchedEventKey"),str)
        }
        for item in new_items:
            if isinstance(item,dict) and item.get("id") in dispatched_keys:
                item["lastDispatchedEventKey"]=dispatched_keys[item["id"]]


def persist(db,event,repo,task,conversation):
    now=datetime.now(timezone.utc).isoformat(timespec="seconds")
    db.execute("BEGIN IMMEDIATE")
    try:
        existing=db.execute(
            "SELECT workflowType,repository FROM workflow_instances WHERE workflowId=?",
            (event["workflowId"],)
        ).fetchone()
        if existing and (existing["workflowType"]!=event["workflowType"] or existing["repository"]!=repo):
            raise ValueError("workflow ID is bound to another type or repository")

        preserve_team_coordinator_state(db,event)
        canonical=json.dumps(event,ensure_ascii=False,sort_keys=True,separators=(",",":"))
        event_key=hashlib.sha256(f"{event['workflowId']}|{task}|{canonical}".encode()).hexdigest()
        inserted=db.execute("""INSERT OR IGNORE INTO workflow_events
        (workflowId,eventKey,workflowType,repository,taskId,conversationId,phase,status,payloadJson,createdAt)
        VALUES (?,?,?,?,?,?,?,?,?,?)""",(event["workflowId"],event_key,event["workflowType"],repo,task or None,
        conversation or None,event["phase"],event["status"],canonical,now)).rowcount
        if not inserted:
            db.commit()
            return False
        db.execute("""INSERT INTO workflow_instances
        (workflowId,workflowType,repository,sourceTaskId,conversationId,phase,status,stateJson,version,createdAt,updatedAt)
        VALUES (?,?,?,?,?,?,?,?,1,?,?)
        ON CONFLICT(workflowId) DO UPDATE SET sourceTaskId=excluded.sourceTaskId,
        conversationId=COALESCE(excluded.conversationId,workflow_instances.conversationId),
        phase=excluded.phase,status=excluded.status,stateJson=excluded.stateJson,
        version=workflow_instances.version+1,updatedAt=excluded.updatedAt""",
        (event["workflowId"],event["workflowType"],repo,task or None,conversation or None,
        event["phase"],event["status"],canonical,now,now))
        db.commit()
        return True
    except Exception:
        db.rollback()
        raise


def record_output(args):
    content=Path(args.output).read_text(encoding="utf-8",errors="replace")
    blocks=re.findall(re.escape(BEGIN)+r"\s*\r?\n(.*?)\r?\n\s*"+re.escape(END),content,flags=re.DOTALL)
    if not blocks:
        print(json.dumps({"recorded":0,"ignored":0}))
        return 0
    db=connect(args.db); recorded=ignored=0
    try:
        for block in blocks:
            if len(block.encode("utf-8"))>262144:
                ignored+=1
                continue
            try:
                event=validate(json.loads(block),args.repo)
                if persist(db,event,args.repo,args.task_id,args.conversation_id):
                    recorded+=1
                else:
                    ignored+=1
            except (json.JSONDecodeError,ValueError) as exc:
                print(f"workflow-state: ignored invalid checkpoint: {exc}",file=sys.stderr)
                ignored+=1
    finally:
        db.close()
    print(json.dumps({"recorded":recorded,"ignored":ignored}))
    return 0

def get_status(args):
    db=connect(args.db)
    try:
        row=db.execute("SELECT * FROM workflow_instances WHERE workflowId=?",(args.workflow_id,)).fetchone()
        if not row:
            print(json.dumps({"found":False,"workflowId":args.workflow_id}))
            return 2
        items=db.execute("SELECT id,taskId,phase,status,payloadJson,createdAt FROM workflow_events WHERE workflowId=? ORDER BY id",(args.workflow_id,)).fetchall()
        workflow=dict(row); workflow["state"]=json.loads(workflow.pop("stateJson"))
        workflow["events"]=[{**dict(item),"payload":json.loads(item["payloadJson"])} for item in items]
        print(json.dumps({"found":True,"workflow":workflow},ensure_ascii=False))
        return 0
    finally:
        db.close()


def get_context(args):
    db=connect(args.db)
    try:
        row=db.execute("""SELECT * FROM workflow_instances
        WHERE repository=? AND conversationId=? AND workflowType=?
        ORDER BY updatedAt DESC LIMIT 1""",
        (args.repo,args.conversation_id,args.workflow_type)).fetchone()
        if not row:
            print(json.dumps({"found":False,"repo":args.repo,"conversationId":args.conversation_id}))
            return 0
        events=db.execute("""SELECT id,taskId,phase,status,payloadJson,createdAt
        FROM workflow_events WHERE workflowId=? ORDER BY id DESC LIMIT 20""",
        (row["workflowId"],)).fetchall()
        workflow=dict(row)
        workflow["state"]=json.loads(workflow.pop("stateJson"))
        workflow["events"]=[{**dict(event),"payload":json.loads(event["payloadJson"])} for event in reversed(events)]
        print(json.dumps({"found":True,"workflow":workflow},ensure_ascii=False))
        return 0
    finally:
        db.close()

def listing(args):
    db=connect(args.db)
    try:
        rows=db.execute("""SELECT workflowId,workflowType,repository,sourceTaskId,conversationId,phase,status,version,createdAt,updatedAt
        FROM workflow_instances WHERE (?='' OR repository=?) ORDER BY updatedAt DESC""",(args.repo,args.repo)).fetchall()
        print(json.dumps({"workflows":[dict(row) for row in rows]},ensure_ascii=False))
        return 0
    finally:
        db.close()

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--db",default="")
    subs=parser.add_subparsers(dest="command",required=True)
    record=subs.add_parser("record-output")
    record.add_argument("--output",required=True); record.add_argument("--repo",required=True)
    record.add_argument("--task-id",default=""); record.add_argument("--conversation-id",default="")
    record.set_defaults(func=record_output)
    status=subs.add_parser("status"); status.add_argument("--workflow-id",required=True); status.set_defaults(func=get_status)
    context=subs.add_parser("context")
    context.add_argument("--repo",required=True)
    context.add_argument("--conversation-id",required=True)
    context.add_argument("--workflow-type",default="sdd")
    context.set_defaults(func=get_context)
    show=subs.add_parser("list"); show.add_argument("--repo",default=""); show.set_defaults(func=listing)
    args=parser.parse_args()
    if not args.db:
        root=os.environ.get("MANUL_DIR",str(Path.home()/".manul"))
        args.db=os.environ.get("MANUL_DB",str(Path(root)/"state/manul.db"))
    return args.func(args)

if __name__=="__main__":
    raise SystemExit(main())
