#!/usr/bin/env python3
"""Mission Control HTTP server — Phase 3.

Serves the dashboard and small JSON/control endpoints backed by flat files.
Python stdlib only: no Flask, no deps. Bind 0.0.0.0:3001 for LAN access.

Endpoints:
  GET /                  -> public/index.html
  GET /api/status        -> ~/.hermes/status/current.json (raw passthrough)
  GET /api/providers     -> provider registry + live status overlay
  GET /api/events?limit  -> last N lines of agent-events.log as JSON array
  POST /api/dispatch     -> validated structured order in the durable queue
  POST /api/agent/control -> pause/resume/interrupt/restart a registered agent
  POST /api/control/global-stop -> set/clear the persistent emergency stop
  POST /api/deploy/decision -> record explicit operator approval or denial
  GET /api/health        -> {"status":"ok","uptime":<seconds>}
"""
import csv
import json
import mimetypes
import os
import re
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOME = os.path.expanduser("~")
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUBLIC = os.path.join(BASE, "public")
TEMPLATES_DIR = os.path.join(BASE, "docs", "task-templates")
PROVIDER_FILE = os.environ.get("HERMES_PROVIDER_FILE", os.path.join(BASE, "config", "providers.json"))

STATUS_FILE = os.environ.get("HERMES_STATUS_FILE", f"{HOME}/.hermes/status/current.json")
EVENT_LOG = os.environ.get("HERMES_EVENT_LOG", f"{HOME}/.hermes/logs/agent-events.log")
# COST_LOG = os.environ.get("HERMES_COST_LOG", f"{HOME}/.hermes/logs/cost-log.csv")  # cost tracking disabled
REQ_DIR = os.environ.get("HERMES_REQUESTS_DIR", f"{HOME}/.hermes/requests")
NOTIF_LOG = os.environ.get("HERMES_NOTIF_LOG", f"{HOME}/.hermes/notifications.log")
PAUSE_DIR = os.environ.get("HERMES_PAUSED_AGENTS_DIR", f"{HOME}/.hermes/paused-agents")
APPROVAL_DIR = os.environ.get("HERMES_APPROVAL_DIR", f"{HOME}/.hermes/approvals")
DEPLOY_DIR = os.environ.get("HERMES_DEPLOY_REQUEST_DIR", f"{HOME}/.hermes/deploy-requests")
# CAP = float(os.environ.get("HERMES_WEEKLY_CAP", "20.0"))  # cost tracking disabled
PORT = int(os.environ.get("MISSION_CONTROL_PORT", "3001"))

START = time.time()


def read_json(path, fallback=None):
    """Read a local JSON file without making an absent optional data source fatal."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return fallback


def load_provider_registry():
    """Return the provider registry, with live status overlaid when available."""
    registry = read_json(PROVIDER_FILE, {"version": 1, "providers": [], "agents": []})
    snapshot = read_json(STATUS_FILE, {}) or {}
    workers = snapshot.get("workers", [])
    by_session = {w.get("session"): w for w in workers if w.get("session")}
    by_name = {w.get("name"): w for w in workers if w.get("name")}

    agents = []
    for configured in registry.get("agents", []):
        agent = dict(configured)
        live = by_session.get(agent.get("session")) or by_name.get(agent.get("name")) or {}
        for key in ("status", "model", "project", "directory", "last_phase", "current_task"):
            if live.get(key) not in (None, ""):
                agent[key] = live[key]
        agent.setdefault("status", "offline")
        if not live and agent.get("session"):
            try:
                if _session_alive(agent["session"]):
                    agent["status"] = "idle"
            except (FileNotFoundError, subprocess.TimeoutExpired):
                pass
        agent["paused"] = os.path.exists(os.path.join(PAUSE_DIR, agent.get("id", "")))
        if agent["paused"]:
            agent["status"] = "paused"
        agents.append(agent)

    provider_counts = {}
    for agent in agents:
        counts = provider_counts.setdefault(agent.get("provider_id"), {"total": 0, "online": 0, "active": 0})
        counts["total"] += 1
        if agent.get("status") not in ("offline", "unknown"):
            counts["online"] += 1
        if agent.get("status") == "active":
            counts["active"] += 1

    providers = []
    for configured in registry.get("providers", []):
        provider = dict(configured)
        provider["counts"] = provider_counts.get(provider.get("id"), {"total": 0, "online": 0, "active": 0})
        providers.append(provider)

    return {**registry, "providers": providers, "agents": agents,
            "demo_recommended": not any(a.get("status") in ("active", "idle", "stuck") for a in agents)}


def find_agent(identifier):
    """Resolve a registry agent by stable id or tmux session name."""
    for agent in load_provider_registry().get("agents", []):
        if identifier in (agent.get("id"), agent.get("session")):
            return agent
    return None


def append_event(correlation_id, event, agent, detail=""):
    """Append one structured event using the established flat-file format."""
    clean = lambda value: str(value or "").replace("|", " ").replace("\n", " ").replace("\r", " ")
    log_dir = os.path.dirname(EVENT_LOG)
    if log_dir:
        os.makedirs(log_dir, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(EVENT_LOG, "a", encoding="utf-8") as f:
        f.write(f"{ts}|{clean(correlation_id)}|{clean(event)}|{clean(agent)}|{clean(detail)}\n")


# cost tracking disabled
# def week_start():
#     """Monday 00:00 UTC of the current week."""
#     now = datetime.now(timezone.utc)
#     d = now - timedelta(days=now.weekday())
#     return d.replace(hour=0, minute=0, second=0, microsecond=0)


def read_events(limit):
    """Last `limit` events as list of dicts. Empty list if no log yet."""
    if not os.path.exists(EVENT_LOG):
        return []
    with open(EVENT_LOG, encoding="utf-8") as f:
        lines = f.read().splitlines()
    out = []
    for line in lines[-limit:]:
        parts = line.split("|", 4)
        if len(parts) != 5:
            continue
        ts, cid, event, agent, detail = parts
        out.append({"ts": ts, "correlation_id": cid, "event": event,
                    "agent": agent, "detail": detail})
    return out


def read_notifications(limit):
    """Last `limit` notifications (ts|level|source|message) as dicts. Empty-safe."""
    if not os.path.exists(NOTIF_LOG):
        return []
    with open(NOTIF_LOG, encoding="utf-8") as f:
        lines = f.read().splitlines()
    out = []
    for line in lines[-limit:]:
        parts = line.split("|", 3)
        if len(parts) != 4:
            continue
        ts, level, source, message = parts
        out.append({"ts": ts, "level": level, "source": source, "message": message})
    return out


# cost tracking disabled
# def cost_summary():
#     """Weekly rollup parsed live from the CSV. Empty-safe."""
#     result = {"total_spend": 0.0, "cap": CAP, "remaining": CAP,
#               "task_count": 0, "by_worker": {}}
#     if not os.path.exists(COST_LOG):
#         return result
#     ws = week_start()
#     total = 0.0
#     with open(COST_LOG, newline="", encoding="utf-8") as f:
#         for row in csv.DictReader(f):
#             try:
#                 ts = datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00"))
#                 cost = float(row["cost_usd"])
#             except (ValueError, KeyError, TypeError):
#                 continue
#             if ts < ws:
#                 continue
#             total += cost
#             result["task_count"] += 1
#             w = row.get("model", "unknown")
#             bw = result["by_worker"].setdefault(w, {"spend": 0.0, "tasks": 0})
#             bw["spend"] = round(bw["spend"] + cost, 2)
#             bw["tasks"] += 1
#     result["total_spend"] = round(total, 2)
#     result["remaining"] = round(CAP - total, 2)
#     return result


def pending_dispatches():
    """All queued dispatch requests, newest first. Empty-safe."""
    out = []
    if os.path.isdir(REQ_DIR):
        for fn in os.listdir(REQ_DIR):
            if not fn.endswith(".json"):
                continue
            try:
                with open(os.path.join(REQ_DIR, fn), encoding="utf-8") as f:
                    out.append(json.load(f))
            except (OSError, ValueError):
                continue
    out.sort(key=lambda r: r.get("created_at", ""), reverse=True)
    return out


def _safe_id(value):
    value = str(value or "")
    return value if re.fullmatch(r"[A-Za-z0-9._:-]+", value) else ""


def _task_text(data):
    """Render structured order fields into the worker-facing task document."""
    prompt = str(data.get("prompt") or data.get("task") or "").strip()
    title = str(data.get("title") or "Untitled order").strip()
    repository = str(data.get("repository") or "").strip()
    branch = str(data.get("branch") or "").strip()
    criteria = data.get("acceptance_criteria") or []
    if isinstance(criteria, str):
        criteria = [line.strip(" -") for line in criteria.splitlines() if line.strip(" -")]

    sections = [f"# {title}"]
    context = []
    if repository:
        context.append(f"Repository: {repository}")
    if branch:
        context.append(f"Requested branch: {branch}")
    if context:
        sections.append("\n".join(context))
    sections.append(prompt)
    if criteria:
        sections.append("Acceptance criteria:\n" + "\n".join(f"- {item}" for item in criteria))
    return "\n\n".join(section for section in sections if section)


def agent_session(session, lines=20):
    """Capture last N lines of a tmux session pane. Returns JSON-safe dict."""
    try:
        result = subprocess.run(
            ["tmux", "capture-pane", "-t", session, "-p", "-S", f"-{lines}"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return {"session": session, "error": "session not found",
                    "output": "", "status": "unknown"}
        raw = result.stdout
        if re.search(r"Spinning|Baking|Hatching|Misting|Thinking|Deliberating", raw):
            status = "active"
        else:
            status = "idle"
        # Strip ANSI escape sequences
        clean = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", raw)
        return {"session": session, "status": status, "output": clean}
    except FileNotFoundError:
        return {"session": session, "error": "tmux not found",
                "output": "", "status": "unknown"}
    except subprocess.TimeoutExpired:
        return {"session": session, "error": "timeout",
                "output": "", "status": "unknown"}



def create_dispatch(body):
    """Validate + persist a dispatch request. Returns (code, response dict)."""
    try:
        data = json.loads(body or b"{}")
    except ValueError:
        return 400, {"error": "invalid JSON body"}
    agent_key = str(data.get("agent", "")).strip()
    task = _task_text(data)
    if not agent_key or not str(data.get("prompt") or data.get("task") or "").strip():
        return 400, {"error": "agent and prompt are required"}
    agent = find_agent(agent_key)
    if not agent:
        return 400, {"error": f"unknown registry agent '{agent_key}'"}
    if agent.get("paused"):
        return 409, {"error": f"{agent.get('name')} is paused; resume the agent before issuing a new order"}
    if subprocess.run(["bash", os.path.join(BASE, "scripts", "global-stop.sh"), "check"],
                      capture_output=True).returncode == 0:
        return 423, {"error": "The Rock is sealed; clear the global stop before issuing orders"}
    priority = str(data.get("priority", "normal")).strip() or "normal"
    if priority not in ("low", "normal", "high", "critical"):
        return 400, {"error": "priority must be low, normal, high, or critical"}

    rid = str(uuid.uuid4())
    # ponytail: correlation-id.sh emits exactly "<uuid>:0" for a root dispatch;
    # replicated inline to skip a subprocess per request.
    cid = f"{rid}:0"
    criteria = data.get("acceptance_criteria") or []
    if isinstance(criteria, str):
        criteria = [line.strip(" -") for line in criteria.splitlines() if line.strip(" -")]
    req = {"request_id": rid, "correlation_id": cid,
           "agent": agent.get("session") or agent.get("id"), "agent_id": agent.get("id"),
           "agent_name": agent.get("name"), "provider_id": agent.get("provider_id"),
           "title": str(data.get("title") or "Untitled order").strip(),
           "repository": str(data.get("repository") or "").strip(),
           "branch": str(data.get("branch") or "").strip(),
           "model": str(data.get("model") or agent.get("model") or "provider default").strip(),
           "approval_policy": str(data.get("approval_policy") or "confirm_deploy").strip(),
           "acceptance_criteria": criteria, "task": task, "priority": priority,
           "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    os.makedirs(REQ_DIR, exist_ok=True)
    with open(os.path.join(REQ_DIR, f"{rid}.json"), "w", encoding="utf-8") as f:
        json.dump(req, f, indent=2)
    append_event(cid, "queued", agent.get("id"), req["title"])
    return 200, {"status": "queued", "request_id": rid, "correlation_id": cid,
                 "agent": agent.get("id"), "provider": agent.get("provider_id")}


def cancel_dispatch(body):
    try:
        data = json.loads(body or b"{}")
    except ValueError:
        return 400, {"error": "invalid JSON body"}
    request_id = _safe_id(data.get("request_id"))
    if not request_id:
        return 400, {"error": "valid request_id is required"}
    path = os.path.join(REQ_DIR, f"{request_id}.json")
    request = read_json(path)
    if not request:
        return 404, {"error": "queued order not found"}
    os.remove(path)
    append_event(request.get("correlation_id"), "cancel", request.get("agent_id") or request.get("agent"),
                 request.get("title") or "queued order cancelled")
    return 200, {"status": "cancelled", "request_id": request_id}


def control_agent(body):
    """Pause a queue lane, interrupt a live task, resume, or restart a registry agent."""
    try:
        data = json.loads(body or b"{}")
    except ValueError:
        return 400, {"error": "invalid JSON body"}
    agent = find_agent(str(data.get("agent", "")).strip())
    action = str(data.get("action", "")).strip()
    if not agent:
        return 404, {"error": "registry agent not found"}
    if action not in ("pause", "resume", "interrupt", "restart"):
        return 400, {"error": "action must be pause, resume, interrupt, or restart"}

    os.makedirs(PAUSE_DIR, exist_ok=True)
    pause_file = os.path.join(PAUSE_DIR, agent["id"])
    session = agent.get("session") or agent["id"]
    cid = f"{uuid.uuid4()}:0"

    if action == "pause":
        with open(pause_file, "w", encoding="utf-8") as f:
            f.write(datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        append_event(cid, "pause", agent["id"], "future orders held at the serial gate")
        return 200, {"status": "paused", "agent": agent["id"]}
    if action == "resume":
        try:
            os.remove(pause_file)
        except FileNotFoundError:
            pass
        append_event(cid, "resume", agent["id"], "serial gate reopened")
        return 200, {"status": "resumed", "agent": agent["id"]}
    if action == "interrupt":
        if not _session_alive(session):
            return 409, {"error": f"session '{session}' is not online"}
        try:
            subprocess.run(["tmux", "send-keys", "-t", session, "C-c"], timeout=5, check=True)
        except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            return 500, {"error": f"interrupt failed: {exc}"}
        append_event(cid, "cancel", agent["id"], "active task interrupted by operator")
        return 200, {"status": "interrupted", "agent": agent["id"]}

    command = agent.get("restart_command") or []
    if not command:
        return 409, {"error": "no restart command configured for this agent"}
    if _session_alive(session):
        return 409, {"error": f"session '{session}' is already online"}
    directory = os.path.expanduser(agent.get("directory") or HOME)
    if not os.path.isdir(directory):
        return 409, {"error": f"registered working directory does not exist: {agent.get('directory')}"}
    try:
        subprocess.run(["tmux", "new-session", "-d", "-s", session, "-c", directory, *command],
                       timeout=10, check=True)
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        return 500, {"error": f"restart failed: {exc}"}
    append_event(cid, "start", agent["id"], "agent session restarted from provider registry")
    return 200, {"status": "restarted", "agent": agent["id"], "session": session}


def global_stop_control(body):
    try:
        data = json.loads(body or b"{}")
    except ValueError:
        return 400, {"error": "invalid JSON body"}
    action = str(data.get("action", "")).strip()
    script = os.path.join(BASE, "scripts", "global-stop.sh")
    if action == "engage":
        reason = str(data.get("reason") or "Sealed from Mission Control")
        result = subprocess.run(["bash", script, "set", reason], capture_output=True, text=True, timeout=10)
        append_event(f"{uuid.uuid4()}:0", "stop", "mission-control", reason)
    elif action == "release":
        result = subprocess.run(["bash", script, "clear"], capture_output=True, text=True, timeout=10)
        append_event(f"{uuid.uuid4()}:0", "start", "mission-control", "global stop released")
    else:
        return 400, {"error": "action must be engage or release"}
    if result.returncode != 0:
        return 500, {"error": result.stderr.strip() or "global stop command failed"}
    return 200, {"status": "stopped" if action == "engage" else "running"}


def deployment_decision(body):
    """Persist an operator's explicit deployment sanction or denial."""
    try:
        data = json.loads(body or b"{}")
    except ValueError:
        return 400, {"error": "invalid JSON body"}
    deploy_id = _safe_id(data.get("deployment_id"))
    decision = str(data.get("decision", "")).strip()
    if not deploy_id or decision not in ("approve", "deny"):
        return 400, {"error": "deployment_id and approve/deny decision are required"}
    os.makedirs(APPROVAL_DIR, exist_ok=True)
    record = {"deployment_id": deploy_id, "decision": decision,
              "reason": str(data.get("reason") or ""),
              "decided_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "decided_by": os.environ.get("USER", "operator")}
    with open(os.path.join(APPROVAL_DIR, f"{deploy_id}.json"), "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2)
    append_event(f"{uuid.uuid4()}:0", decision, "mission-control", f"deployment {deploy_id}")
    return 200, {"status": decision, "deployment_id": deploy_id}


def list_deployments():
    out = []
    if os.path.isdir(DEPLOY_DIR):
        for filename in os.listdir(DEPLOY_DIR):
            if filename.endswith(".json"):
                item = read_json(os.path.join(DEPLOY_DIR, filename))
                if item:
                    item.setdefault("id", filename[:-5])
                    if os.path.exists(os.path.join(APPROVAL_DIR, f"{item['id']}.json")):
                        continue
                    out.append(item)
    out.sort(key=lambda item: item.get("created_at", ""), reverse=True)
    return out


def _session_alive(session):
    try:
        result = subprocess.run(["tmux", "has-session", "-t", session],
                                capture_output=True, timeout=5)
        return result.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def send_keys(body):
    """Send input to a live tmux session. Returns (code, dict)."""
    try:
        data = json.loads(body or b"{}")
    except ValueError:
        return 400, {"error": "invalid JSON body"}
    session = str(data.get("session", "")).strip()
    text = str(data.get("input", ""))
    submit = bool(data.get("submit", True))
    if not session:
        return 400, {"error": "session is required"}
    if not text.strip():
        return 400, {"error": "input is empty"}
    if not find_agent(session):
        return 403, {"error": "session is not present in the provider registry"}
    try:
        if not _session_alive(session):
            return 400, {"error": f"session '{session}' not found"}
        subprocess.run(["tmux", "send-keys", "-t", session, text], timeout=5, check=True)
        if submit:
            # ponytail: two-Enter quirk — first inserts, second (after 5s) submits.
            # Same as dispatch-consumer.sh; upgrade path is a real key protocol if this drifts.
            subprocess.run(["tmux", "send-keys", "-t", session, "Enter"], timeout=5, check=True)
            time.sleep(5)
            subprocess.run(["tmux", "send-keys", "-t", session, "Enter"], timeout=5)
        return 200, {"status": "sent", "session": session}
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        return 400, {"error": f"send failed: {e}"}


def clear_session(body):
    """Send /clear + Enter to a live tmux session. Returns (code, dict)."""
    try:
        data = json.loads(body or b"{}")
    except ValueError:
        return 400, {"error": "invalid JSON body"}
    session = str(data.get("session", "")).strip()
    if not session:
        return 400, {"error": "session is required"}
    if not find_agent(session):
        return 403, {"error": "session is not present in the provider registry"}
    try:
        if not _session_alive(session):
            return 400, {"error": f"session '{session}' not found"}
        subprocess.run(["tmux", "send-keys", "-t", session, "/clear"], timeout=5, check=True)
        subprocess.run(["tmux", "send-keys", "-t", session, "Enter"], timeout=5, check=True)
        time.sleep(5)
        subprocess.run(["tmux", "send-keys", "-t", session, "Enter"], timeout=5)
        return 200, {"status": "cleared", "session": session}
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        return 400, {"error": f"clear failed: {e}"}


def _days(period):
    """Parse '7d' -> 7. Defaults to 7, clamps to 1..90."""
    m = re.match(r"(\d+)", str(period or ""))
    n = int(m.group(1)) if m else 7
    return max(1, min(90, n))


# cost tracking disabled
# def cost_history(period="7d"):
#     """Per-day spend + task count for the last N days, oldest first. Empty-safe."""
#     n = _days(period)
#     today = datetime.now(timezone.utc).date()
#     buckets = {(today - timedelta(days=i)).isoformat(): {"spend": 0.0, "tasks": 0}
#                for i in range(n)}
#     if os.path.exists(COST_LOG):
#         with open(COST_LOG, newline="", encoding="utf-8") as f:
#             for row in csv.DictReader(f):
#                 try:
#                     d = datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")).date().isoformat()
#                     cost = float(row["cost_usd"])
#                 except (ValueError, KeyError, TypeError):
#                     continue
#                 if d in buckets:
#                     buckets[d]["spend"] = round(buckets[d]["spend"] + cost, 2)
#                     buckets[d]["tasks"] += 1
#     return [{"date": d, "spend": buckets[d]["spend"], "tasks": buckets[d]["tasks"]}
#             for d in sorted(buckets)]


def events_trend(period="7d", agent=""):
    """Per-day total/failed/circuit_break event counts, oldest first. Empty-safe."""
    n = _days(period)
    today = datetime.now(timezone.utc).date()
    buckets = {(today - timedelta(days=i)).isoformat():
               {"total": 0, "failed": 0, "circuit_breaks": 0} for i in range(n)}
    fails = {"fail", "qa_fail", "deny"}
    if os.path.exists(EVENT_LOG):
        with open(EVENT_LOG, encoding="utf-8") as f:
            for line in f.read().splitlines():
                parts = line.split("|", 4)
                if len(parts) != 5:
                    continue
                ts, _cid, event, ag, _detail = parts
                if agent and ag != agent:
                    continue
                d = ts[:10]
                if d not in buckets:
                    continue
                buckets[d]["total"] += 1
                if event in fails:
                    buckets[d]["failed"] += 1
                if event == "circuit_break":
                    buckets[d]["circuit_breaks"] += 1
    return [{"date": d, **buckets[d]} for d in sorted(buckets)]


def list_templates():
    """Task templates from docs/task-templates/*.md. Empty-safe."""
    out = []
    if os.path.isdir(TEMPLATES_DIR):
        for fn in sorted(os.listdir(TEMPLATES_DIR)):
            if not fn.endswith(".md"):
                continue
            name = fn[:-3]
            with open(os.path.join(TEMPLATES_DIR, fn), encoding="utf-8") as f:
                content = f.read()
            out.append({"name": name,
                        "title": name.replace("-", " ").title(),
                        "content": content})
    return out


def list_pipelines():
    """Active and recently-completed dev pipelines, newest first. Empty-safe."""
    base = os.path.join(HOME, ".hermes", "dev-pipeline")
    out = []
    if not os.path.isdir(base):
        return out

    def rd(p):
        try:
            with open(p, encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            return ""

    for pid in sorted(os.listdir(base), reverse=True):
        pdir = os.path.join(base, pid)
        state = rd(os.path.join(pdir, "state"))
        if not state:
            continue
        stages = {}
        for s in ("research", "scaffold", "build"):
            sd = os.path.join(pdir, s)
            stages[s] = {
                "agent": rd(os.path.join(sd, "agent")),
                "sent_at": rd(os.path.join(sd, "sent_at")),
                "completed_at": rd(os.path.join(sd, "completed_at")),
                "has_output": os.path.isfile(os.path.join(sd, "output.md")),
            }
        out.append({"id": pid, "name": rd(os.path.join(pdir, "name")) or pid[:8],
                    "state": state, "created_at": rd(os.path.join(pdir, "created_at")),
                    "stages": stages})
    return out


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._send(204, "")

    def do_POST(self):
        path = urlparse(self.path).path
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n) if n else b""
        if path == "/api/dispatch":
            self._send(*create_dispatch(body))
        elif path == "/api/dispatch/cancel":
            self._send(*cancel_dispatch(body))
        elif path == "/api/agent/send":
            self._send(*send_keys(body))
        elif path == "/api/agent/clear":
            self._send(*clear_session(body))
        elif path == "/api/agent/control":
            self._send(*control_agent(body))
        elif path == "/api/control/global-stop":
            self._send(*global_stop_control(body))
        elif path == "/api/deploy/decision":
            self._send(*deployment_decision(body))
        else:
            self._send(404, {"error": "not found"})

    def _file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                self._send(200, f.read().decode("utf-8", "replace"), ctype)
        except FileNotFoundError:
            self._send(404, {"error": f"not found: {os.path.basename(path)}"})

    def _binary_file(self, path):
        try:
            with open(path, "rb") as f:
                self._send(200, f.read(), mimetypes.guess_type(path)[0] or "application/octet-stream")
        except FileNotFoundError:
            self._send(404, {"error": f"not found: {os.path.basename(path)}"})

    def do_GET(self):
        u = urlparse(self.path)
        path = u.path
        if path in ("/", "/index.html"):
            self._file(os.path.join(PUBLIC, "index.html"), "text/html; charset=utf-8")
        elif path.startswith("/assets/") and ".." not in path:
            self._binary_file(os.path.join(PUBLIC, path.lstrip("/")))
        elif path == "/api/status":
            # raw passthrough; if snapshot missing, say so gracefully
            if os.path.exists(STATUS_FILE):
                self._file(STATUS_FILE, "application/json")
            else:
                self._send(200, {"error": "no snapshot yet — run status-snapshot.sh"})
        elif path == "/api/events":
            limit = int((parse_qs(u.query).get("limit", ["50"])[0]) or 50)
            self._send(200, read_events(limit))
        # cost tracking disabled
        # elif path == "/api/cost/summary":
        #     self._send(200, cost_summary())
        # elif path == "/api/cost/history":
        #     self._send(200, cost_history((parse_qs(u.query).get("period", ["7d"])[0])))
        elif path == "/api/events/trend":
            qs = parse_qs(u.query)
            self._send(200, events_trend(qs.get("period", ["7d"])[0],
                                         (qs.get("agent") or [""])[0]))
        elif path == "/api/templates":
            self._send(200, list_templates())
        elif path == "/api/pipelines":
            self._send(200, list_pipelines())
        elif path == "/api/providers":
            self._send(200, load_provider_registry())
        elif path == "/api/deployments":
            self._send(200, list_deployments())
        elif path == "/api/agent/session":
            qs = parse_qs(u.query)
            session = (qs.get("session") or [""])[0]
            lim = int((qs.get("lines") or ["20"])[0])
            if not session:
                self._send(400, {"error": "session query parameter required"})
            else:
                self._send(200, agent_session(session, lim))
        elif path == "/api/notifications":
            limit = int((parse_qs(u.query).get("limit", ["50"])[0]) or 50)
            self._send(200, read_notifications(limit))
        elif path == "/api/dispatch/pending":
            self._send(200, pending_dispatches())
        elif path == "/api/health":
            self._send(200, {"status": "ok", "uptime": round(time.time() - START)})
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, fmt, *args):  # to stdout instead of stderr
        sys.stdout.write("%s - %s\n" % (self.address_string(), fmt % args))
        sys.stdout.flush()


def main():
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)

    def shutdown(*_):
        print("\nshutting down…")
        raise KeyboardInterrupt

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)
    print(f"Mission Control on http://0.0.0.0:{PORT}  (serving {PUBLIC})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
