#!/usr/bin/env python3
"""Mission Control HTTP server — Phase 3.

Serves the dashboard and small JSON/control endpoints backed by flat files.
Python stdlib only: no Flask, no deps. Bind 0.0.0.0:3001 for LAN access.

Endpoints:
  GET /                  -> public/index.html
  GET /api/status        -> ~/.hermes/status/current.json (raw passthrough)
  GET /api/providers     -> provider registry + live status overlay
  GET /api/events?limit  -> last N lines of agent-events.log as JSON array
  GET /api/task-runs     -> Phase 5e delivery/QA state
  GET /api/tickets       -> Phase 5g report-only ticket surface
  GET /api/learnings     -> Phase 5d human-curated compound learnings
  POST /api/dispatch     -> validated structured order in the durable queue
  POST /api/agent/control -> pause/resume/interrupt/restart a registered agent
  POST /api/control/global-stop -> set/clear the persistent emergency stop
  POST /api/deploy/decision -> record explicit operator approval or denial
  POST /api/ticket/review -> operator completion/block decision
  POST /api/learnings    -> append one operator-curated learning
  GET /api/health        -> {"status":"ok","uptime":<seconds>}
"""
import csv
import fcntl
import hashlib
import json
import mimetypes
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from collections import deque
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

SERVER_DIR = os.path.dirname(os.path.abspath(__file__))
if SERVER_DIR not in sys.path:
    sys.path.insert(0, SERVER_DIR)

from deployment_approval import (  # noqa: E402
    ApprovalStateError,
    InvalidDeploymentId,
    MissingRequest,
    list_pending,
    record_decision,
)

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
TASK_RUN_DIR = os.environ.get("HERMES_TASK_RUN_DIR", f"{HOME}/.hermes/task-runs")
TICKET_DIR = os.environ.get("HERMES_TICKET_DIR", f"{HOME}/vaults/kevin/tickets")
LEARNINGS_FILE = os.environ.get("HERMES_LEARNINGS_FILE", f"{HOME}/hermes-learnings.md")
LEARNINGS_LOCK = os.environ.get(
    "HERMES_LEARNINGS_LOCK", f"{HOME}/.hermes/hermes-learnings.lock"
)
STOP_FILE = os.environ.get("HERMES_STOP_FILE", f"{HOME}/.hermes/stop")
DISPATCH_LOCK = os.environ.get(
    "HERMES_DISPATCH_LOCK", f"{HOME}/.hermes/dispatch-consumer.lock"
)
# CAP = float(os.environ.get("HERMES_WEEKLY_CAP", "20.0"))  # cost tracking disabled
PORT = int(os.environ.get("MISSION_CONTROL_PORT", "3001"))
MAX_REQUEST_BODY_BYTES = int(
    os.environ.get("MISSION_CONTROL_MAX_BODY_BYTES", str(64 * 1024))
)
try:
    SNAPSHOT_STALE_SECONDS = max(
        1, min(86400, int(os.environ.get("MISSION_CONTROL_SNAPSHOT_STALE_SECONDS", "300")))
    )
except ValueError:
    SNAPSHOT_STALE_SECONDS = 300


def _normalize_origin(value):
    """Return a strict scheme://authority origin, or an empty string."""
    value = str(value or "").strip()
    if not value or value.casefold() == "null":
        return ""
    try:
        parsed = urlparse(value)
    except ValueError:
        return ""
    if (
        parsed.scheme not in ("http", "https")
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or parsed.params
        or parsed.query
        or parsed.fragment
    ):
        return ""
    return f"{parsed.scheme.casefold()}://{parsed.netloc.casefold()}"


ALLOWED_ORIGINS = {
    origin
    for origin in (
        _normalize_origin(value)
        for value in os.environ.get(
            "MISSION_CONTROL_ALLOWED_ORIGINS", ""
        ).split(",")
    )
    if origin
}

START = time.time()


def read_json(path, fallback=None):
    """Read a local JSON file without making an absent optional data source fatal."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return fallback


def read_json_object(path, fallback=None):
    """Read a JSON object, rejecting valid JSON with the wrong top-level shape."""
    value = read_json(path, fallback)
    return value if isinstance(value, dict) else fallback


class InvalidJsonBody(ValueError):
    """The request body is not a JSON object."""


class InvalidQueryParameter(ValueError):
    """A query parameter is not an integer inside its endpoint's safe bounds."""


def parse_json_object(body):
    """Decode a request body and require a top-level JSON object."""
    try:
        value = json.loads(body or b"{}")
    except (TypeError, ValueError) as exc:
        raise InvalidJsonBody("invalid JSON body") from exc
    if not isinstance(value, dict):
        raise InvalidJsonBody("JSON body must be an object")
    return value


def bounded_query_int(query, name, default, minimum, maximum):
    """Parse one bounded integer query parameter or raise a controlled error."""
    raw = (query.get(name) or [str(default)])[0]
    if raw in (None, ""):
        raw = str(default)
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise InvalidQueryParameter(
            f"{name} must be an integer from {minimum} to {maximum}"
        ) from exc
    if not minimum <= value <= maximum:
        raise InvalidQueryParameter(
            f"{name} must be from {minimum} to {maximum}"
        )
    return value


def _safe_text(value, default=""):
    return value if isinstance(value, str) else default


def _stop_file():
    """Honor runtime test/service overrides without relying on a stale snapshot."""
    return os.environ.get("HERMES_STOP_FILE", STOP_FILE)


def _dispatch_lock_file():
    return (
        os.environ.get("HERMES_DISPATCH_LOCK")
        or os.environ.get("HERMES_DISPATCH_CONSUMER_LOCK")
        or DISPATCH_LOCK
    )


def atomic_json_write(path, value):
    """Write JSON beside its destination, fsync, then atomically replace."""
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        prefix=f".{os.path.basename(path)}.", dir=directory or "."
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(value, f, indent=2)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def load_provider_registry():
    """Return the provider registry, with live status overlaid when available."""
    fallback = {"version": 1, "providers": [], "agents": []}
    registry = read_json_object(PROVIDER_FILE, fallback) or fallback
    snapshot = read_json_object(STATUS_FILE, {}) or {}
    workers_value = snapshot.get("workers", [])
    workers = (
        [worker for worker in workers_value if isinstance(worker, dict)]
        if isinstance(workers_value, list)
        else []
    )
    by_session = {
        w["session"]: w for w in workers if isinstance(w.get("session"), str)
    }
    by_name = {w["name"]: w for w in workers if isinstance(w.get("name"), str)}

    agents = []
    configured_agents = registry.get("agents", [])
    if not isinstance(configured_agents, list):
        configured_agents = []
    for configured in configured_agents:
        if not isinstance(configured, dict):
            continue
        agent = dict(configured)
        agent_id = _safe_id(agent.get("id"))
        session = _safe_tmux_session(agent.get("session") or agent_id)
        if not agent_id or not session:
            continue
        agent["id"] = agent_id
        agent["session"] = session
        agent["name"] = _safe_text(agent.get("name"), agent_id)
        agent["provider_id"] = _safe_id(agent.get("provider_id"))
        for key in (
            "status",
            "model",
            "project",
            "directory",
            "last_phase",
            "current_task",
            "role",
        ):
            agent[key] = _safe_text(agent.get(key))
        command = agent.get("restart_command")
        agent["restart_command"] = (
            command
            if isinstance(command, list)
            and command
            and all(isinstance(item, str) and item for item in command)
            else []
        )
        live = by_session.get(session) or by_name.get(agent["name"]) or {}
        for key in ("status", "model", "project", "directory", "last_phase", "current_task"):
            if isinstance(live.get(key), str) and live.get(key):
                agent[key] = live[key]
        if not agent.get("status"):
            agent["status"] = "offline"
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
        counts = provider_counts.setdefault(
            agent.get("provider_id"), {"total": 0, "online": 0, "active": 0}
        )
        counts["total"] += 1
        if agent.get("status") not in ("offline", "unknown"):
            counts["online"] += 1
        if agent.get("status") == "active":
            counts["active"] += 1

    providers = []
    configured_providers = registry.get("providers", [])
    if not isinstance(configured_providers, list):
        configured_providers = []
    for configured in configured_providers:
        if not isinstance(configured, dict) or not _safe_id(configured.get("id")):
            continue
        provider = dict(configured)
        provider["id"] = _safe_id(provider["id"])
        provider["name"] = _safe_text(provider.get("name"), provider["id"])
        provider["counts"] = provider_counts.get(provider.get("id"), {"total": 0, "online": 0, "active": 0})
        providers.append(provider)

    return {**registry, "providers": providers, "agents": agents,
            "demo_recommended": not any(a.get("status") in ("active", "idle", "stuck") for a in agents)}


def find_agent(identifier):
    """Resolve a registry agent by stable id or tmux session name."""
    identifier = str(identifier or "").strip()
    for agent in load_provider_registry().get("agents", []):
        if identifier in (agent.get("id"), agent.get("session")):
            return agent
    return None


def resolve_agent_target(identifier):
    """Return a registered agent and its canonical exact tmux session target."""
    agent = find_agent(identifier)
    if not agent:
        return None
    session = _safe_tmux_session(agent.get("session"))
    return (agent, session) if session else None


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
    limit = max(1, min(500, int(limit)))
    with open(EVENT_LOG, encoding="utf-8") as f:
        lines = deque(f, maxlen=limit)
    out = []
    for line in lines:
        parts = line.rstrip("\r\n").split("|", 4)
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
    limit = max(1, min(500, int(limit)))
    with open(NOTIF_LOG, encoding="utf-8") as f:
        lines = deque(f, maxlen=limit)
    out = []
    for line in lines:
        parts = line.rstrip("\r\n").split("|", 3)
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
            request = read_json_object(os.path.join(REQ_DIR, fn))
            if not request:
                continue
            request_id = _safe_id(request.get("request_id"))
            if not request_id or fn != f"{request_id}.json":
                continue
            out.append(request)
    out.sort(key=lambda r: _safe_text(r.get("created_at")), reverse=True)
    return out


def persist_queued_task_run(request):
    """Create the durable order ledger entry before exposing it to the consumer."""
    request_id = _safe_id(request.get("request_id"))
    if not request_id:
        raise ValueError("request has an invalid request_id")
    task_dir = os.path.join(TASK_RUN_DIR, request_id)
    request_path = os.path.join(task_dir, "request.json")
    atomic_json_write(request_path, request)
    with open(request_path, "rb") as f:
        request_sha256 = hashlib.sha256(f.read()).hexdigest()
    queued_at = request.get("created_at") or datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    atomic_json_write(os.path.join(task_dir, "state.json"), {
        "request_id": request_id,
        "correlation_id": request.get("correlation_id", ""),
        "status": "queued",
        "queued_at": queued_at,
        "agent": request.get("agent_id") or request.get("agent") or "",
        "ticket_id": request.get("ticket_id") or "",
        "source_ticket": request.get("source_ticket") or "",
        "request_sha256": request_sha256,
    })


def update_task_run_state(request, status, timestamp_field):
    """Transition an existing order ledger entry without discarding prior state."""
    request_id = _safe_id(request.get("request_id"))
    if not request_id:
        return
    task_dir = os.path.join(TASK_RUN_DIR, request_id)
    state_path = os.path.join(task_dir, "state.json")
    if not os.path.exists(state_path):
        persist_queued_task_run(request)
    state = read_json_object(state_path, {}) or {}
    state.update({
        "request_id": request_id,
        "correlation_id": request.get("correlation_id", ""),
        "status": status,
        timestamp_field: datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    atomic_json_write(state_path, state)


def _safe_id(value):
    value = str(value or "")
    return value if re.fullmatch(r"[A-Za-z0-9._:-]+", value) else ""


def _safe_tmux_session(value):
    """Tmux session names only; window/pane selectors are deliberately excluded."""
    value = str(value or "")
    return value if re.fullmatch(r"[A-Za-z0-9_.-]+", value) else ""


def learning_preamble():
    """Return a bounded copy of the human-curated Phase 5d learning file."""
    try:
        with open(LEARNINGS_FILE, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return ""
    return content[-12000:].strip()


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
    learnings = learning_preamble()
    if learnings:
        sections.append("## Relevant Hermes Learnings\n" + learnings)
    context = []
    if repository:
        context.append(f"Repository: {repository}")
    if branch:
        context.append(f"Requested branch: {branch}")
    if context:
        sections.append("\n".join(context))
    sections.append(prompt)
    if criteria:
        sections.append("## Acceptance Criteria\n" + "\n".join(f"- {item}" for item in criteria))
    return "\n\n".join(section for section in sections if section)


def agent_session(identifier, lines=20):
    """Capture a bounded pane tail for a registered canonical tmux session."""
    target = resolve_agent_target(identifier)
    if not target:
        return 403, {"error": "session is not present in the provider registry"}
    _agent, session = target
    try:
        lines = max(1, min(500, int(lines)))
    except (TypeError, ValueError):
        return 400, {"error": "lines must be an integer from 1 to 500"}
    try:
        result = subprocess.run(
            ["tmux", "capture-pane", "-t", session, "-p", "-S", f"-{lines}"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return 200, {"session": session, "error": "session not found",
                         "output": "", "status": "unknown"}
        raw = result.stdout
        if re.search(r"Spinning|Baking|Hatching|Misting|Thinking|Deliberating", raw):
            status = "active"
        else:
            status = "idle"
        # Strip ANSI escape sequences
        clean = re.sub(r"\x1b\[[0-9;]*[a-zA-Z]", "", raw)
        return 200, {"session": session, "status": status, "output": clean}
    except FileNotFoundError:
        return 200, {"session": session, "error": "tmux not found",
                     "output": "", "status": "unknown"}
    except subprocess.TimeoutExpired:
        return 200, {"session": session, "error": "timeout",
                     "output": "", "status": "unknown"}



def create_dispatch(body):
    """Validate + persist a dispatch request. Returns (code, response dict)."""
    try:
        data = parse_json_object(body)
    except InvalidJsonBody as exc:
        return 400, {"error": str(exc)}
    agent_key = str(data.get("agent", "")).strip()
    if not agent_key or not str(data.get("prompt") or data.get("task") or "").strip():
        return 400, {"error": "agent and prompt are required"}
    agent = find_agent(agent_key)
    if not agent:
        return 400, {"error": f"unknown registry agent '{agent_key}'"}
    if agent.get("paused"):
        return 409, {"error": f"{agent.get('name')} is paused; resume the agent before issuing a new order"}
    if os.path.isfile(_stop_file()):
        return 423, {"error": "The Rock is sealed; clear the global stop before issuing orders"}
    priority = str(data.get("priority", "normal")).strip() or "normal"
    if priority not in ("low", "normal", "high", "critical"):
        return 400, {"error": "priority must be low, normal, high, or critical"}

    qa_mode = str(data.get("qa_mode") or "commit").strip()
    if qa_mode not in ("commit", "report"):
        return 400, {"error": "qa_mode must be commit or report"}
    qa_command = str(data.get("qa_command") or "").strip()
    if len(qa_command) > 1000:
        return 400, {"error": "qa_command exceeds 1000 characters"}
    required_files = data.get("required_files") or []
    if isinstance(required_files, str):
        required_files = [
            line.strip() for line in required_files.splitlines() if line.strip()
        ]
    if not isinstance(required_files, list) or len(required_files) > 30:
        return 400, {"error": "required_files must be a list of at most 30 paths"}
    required_files = [str(path).strip() for path in required_files if str(path).strip()]
    if any(len(path) > 500 for path in required_files):
        return 400, {"error": "required file path exceeds 500 characters"}

    rid = str(uuid.uuid4())
    # ponytail: correlation-id.sh emits exactly "<uuid>:0" for a root dispatch;
    # replicated inline to skip a subprocess per request.
    cid = f"{rid}:0"
    result_file = f"/tmp/hermes-result-{rid}.md"
    task = _task_text(data)
    if qa_mode == "report":
        delivery = (
            "## Delivery Protocol\n"
            f"Write the final report to `{result_file}`, then signal Hermes "
            "asynchronously with:\n\n"
            f"`~/.hermes/scripts/hermes-request.sh qa \"{rid}\" "
            f"--result-file \"{result_file}\" --correlation-id \"{cid}\"`\n\n"
            "The command returns immediately. Hermes—not the worker—runs the "
            "concrete QA gate."
        )
    else:
        delivery = (
            "## Delivery Protocol\n"
            "After the implementation is committed and the worktree is ready for "
            "verification, signal Hermes asynchronously with:\n\n"
            f"`~/.hermes/scripts/hermes-request.sh qa \"{rid}\" "
            f"--correlation-id \"{cid}\"`\n\n"
            "The command returns immediately. Hermes—not the worker—runs the "
            "concrete QA gate."
        )
    task = f"{task}\n\n{delivery}"

    criteria = data.get("acceptance_criteria") or []
    if isinstance(criteria, str):
        criteria = [line.strip(" -") for line in criteria.splitlines() if line.strip(" -")]
    branch = str(data.get("branch") or "").strip()
    qa_checks = []
    if qa_mode == "commit":
        qa_checks.extend(({"type": "commit_advanced"}, {"type": "clean_worktree"}))
    else:
        qa_checks.append({"type": "result_present"})
    if branch:
        qa_checks.append({"type": "branch_matches", "value": branch})
    qa_checks.extend({"type": "file_exists", "value": path} for path in required_files)
    if qa_command:
        qa_checks.append({"type": "command_exit_zero", "value": qa_command})

    repository = str(data.get("repository") or "").strip()
    candidates = []
    if repository:
        expanded = os.path.expanduser(repository)
        candidates.extend((expanded, os.path.join(HOME, repository),
                           os.path.join(HOME, os.path.basename(repository))))
    configured_directory = os.path.expanduser(str(agent.get("directory") or ""))
    if configured_directory:
        candidates.append(configured_directory)
    working_directory = next(
        (os.path.realpath(path) for path in candidates if os.path.isdir(path)), ""
    )
    req = {"request_id": rid, "correlation_id": cid,
           "agent": agent.get("session") or agent.get("id"), "agent_id": agent.get("id"),
           "agent_name": agent.get("name"), "provider_id": agent.get("provider_id"),
           "title": str(data.get("title") or "Untitled order").strip(),
           "summary": str(data.get("prompt") or data.get("task") or "").strip(),
           "repository": repository, "working_directory": working_directory,
           "branch": branch,
           "model": str(data.get("model") or agent.get("model") or "provider default").strip(),
           "approval_policy": str(data.get("approval_policy") or "confirm_deploy").strip(),
           "acceptance_criteria": criteria, "qa_required": True,
           "qa_mode": qa_mode, "qa_checks": qa_checks,
           "task": task, "priority": priority,
           "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    try:
        # The history record is written first so a fast serial consumer cannot
        # make an accepted order disappear between dashboard refreshes.
        persist_queued_task_run(req)
        atomic_json_write(os.path.join(REQ_DIR, f"{rid}.json"), req)
    except OSError as error:
        try:
            update_task_run_state(req, "queue_failed", "failed_at")
        except OSError:
            pass
        append_event(cid, "fail", agent.get("id"), f"queue persistence failed: {error}")
        return 500, {"error": "order could not be persisted to the durable queue"}
    append_event(cid, "queued", agent.get("id"), req["title"])
    return 200, {"status": "queued", "request_id": rid, "correlation_id": cid,
                 "agent": agent.get("id"), "provider": agent.get("provider_id")}


def cancel_dispatch(body):
    try:
        data = parse_json_object(body)
    except InvalidJsonBody as exc:
        return 400, {"error": str(exc)}
    request_id = _safe_id(data.get("request_id"))
    if not request_id:
        return 400, {"error": "valid request_id is required"}
    lock_path = _dispatch_lock_file()
    try:
        os.makedirs(os.path.dirname(lock_path) or ".", exist_ok=True)
        with open(lock_path, "a+", encoding="utf-8") as lock:
            try:
                fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 409, {
                    "error": (
                        "the serial consumer is processing the queue; "
                        "retry after the current dispatch boundary"
                    )
                }
            path = os.path.join(REQ_DIR, f"{request_id}.json")
            request = read_json_object(path)
            if not request or request.get("request_id") != request_id:
                return 404, {"error": "queued order not found"}
            try:
                os.remove(path)
            except FileNotFoundError:
                return 409, {
                    "error": "the order was claimed by the serial consumer"
                }
            update_task_run_state(request, "cancelled", "cancelled_at")
            append_event(
                request.get("correlation_id"),
                "cancel",
                request.get("agent_id") or request.get("agent"),
                request.get("title") or "queued order cancelled",
            )
            return 200, {"status": "cancelled", "request_id": request_id}
    except OSError as exc:
        return 500, {"error": f"queued order could not be cancelled: {exc}"}


def control_agent(body):
    """Pause a queue lane, interrupt a live task, resume, or restart a registry agent."""
    try:
        data = parse_json_object(body)
    except InvalidJsonBody as exc:
        return 400, {"error": str(exc)}
    target = resolve_agent_target(str(data.get("agent", "")).strip())
    action = str(data.get("action", "")).strip()
    if not target:
        return 404, {"error": "registry agent not found"}
    agent, session = target
    if action not in ("pause", "resume", "interrupt", "restart"):
        return 400, {"error": "action must be pause, resume, interrupt, or restart"}

    os.makedirs(PAUSE_DIR, exist_ok=True)
    pause_file = os.path.join(PAUSE_DIR, agent["id"])
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
        data = parse_json_object(body)
    except InvalidJsonBody as exc:
        return 400, {"error": str(exc)}
    action = str(data.get("action", "")).strip()
    script = os.path.join(BASE, "scripts", "global-stop.sh")
    before = os.path.isfile(_stop_file())
    if action == "engage":
        reason = str(data.get("reason") or "Sealed from Mission Control")
        argv = ["bash", script, "set", reason]
    elif action == "release":
        reason = "global stop released"
        argv = ["bash", script, "clear"]
    else:
        return 400, {"error": "action must be engage or release"}
    try:
        result = subprocess.run(
            argv, capture_output=True, text=True, timeout=10, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 500, {"error": f"global stop command failed: {exc}"}
    if result.returncode != 0:
        return 500, {"error": result.stderr.strip() or "global stop command failed"}
    after = os.path.isfile(_stop_file())
    expected = action == "engage"
    if after != expected:
        return 500, {"error": "global stop command did not persist the requested state"}
    changed = before != after
    if changed:
        append_event(
            f"{uuid.uuid4()}:0",
            "stop" if after else "start",
            "mission-control",
            reason,
        )
    return 200, {
        "status": "stopped" if after else "running",
        "idempotent": not changed,
    }


def deployment_decision(body):
    """Persist one immutable, idempotent operator deployment decision."""
    try:
        data = parse_json_object(body)
    except InvalidJsonBody as exc:
        return 400, {"error": str(exc)}
    deploy_id = str(data.get("deployment_id") or "")
    decision = str(data.get("decision", "")).strip()
    if not deploy_id or decision not in ("approve", "deny"):
        return 400, {"error": "deployment_id and approve/deny decision are required"}
    try:
        result = record_decision(
            DEPLOY_DIR,
            APPROVAL_DIR,
            deploy_id,
            decision,
            str(data.get("reason") or ""),
            os.environ.get("USER", "operator"),
        )
    except InvalidDeploymentId as exc:
        return 400, {"error": str(exc)}
    except MissingRequest as exc:
        return 404, {"error": str(exc)}
    except ApprovalStateError as exc:
        return 409, {"error": str(exc)}

    if not result["idempotent"]:
        append_event(
            f"{uuid.uuid4()}:0",
            decision,
            "mission-control",
            f"deployment {deploy_id}",
        )
    return 200, result


def list_deployments():
    """Validated pending deployment requests from the shared approval contract."""
    try:
        return list_pending(DEPLOY_DIR, APPROVAL_DIR)
    except (ApprovalStateError, OSError, ValueError):
        return []


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
        data = parse_json_object(body)
    except InvalidJsonBody as exc:
        return 400, {"error": str(exc)}
    requested = str(data.get("session", "")).strip()
    text = str(data.get("input", ""))
    submit = bool(data.get("submit", True))
    if not requested:
        return 400, {"error": "session is required"}
    if not text.strip():
        return 400, {"error": "input is empty"}
    target = resolve_agent_target(requested)
    if not target:
        return 403, {"error": "session is not present in the provider registry"}
    _agent, session = target
    try:
        if not _session_alive(session):
            return 400, {"error": f"session '{session}' not found"}
        subprocess.run(["tmux", "send-keys", "-t", session, text], timeout=5, check=True)
        if submit:
            # ponytail: two-Enter quirk — first inserts, second (after 5s) submits.
            # Same as dispatch-consumer.sh; upgrade path is a real key protocol if this drifts.
            subprocess.run(["tmux", "send-keys", "-t", session, "Enter"], timeout=5, check=True)
            time.sleep(5)
            subprocess.run(
                ["tmux", "send-keys", "-t", session, "Enter"],
                timeout=5,
                check=True,
            )
        return 200, {"status": "sent", "session": session}
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        return 400, {"error": f"send failed: {e}"}


def clear_session(body):
    """Send /clear + Enter to a live tmux session. Returns (code, dict)."""
    try:
        data = parse_json_object(body)
    except InvalidJsonBody as exc:
        return 400, {"error": str(exc)}
    requested = str(data.get("session", "")).strip()
    if not requested:
        return 400, {"error": "session is required"}
    target = resolve_agent_target(requested)
    if not target:
        return 403, {"error": "session is not present in the provider registry"}
    _agent, session = target
    try:
        if not _session_alive(session):
            return 400, {"error": f"session '{session}' not found"}
        subprocess.run(["tmux", "send-keys", "-t", session, "/clear"], timeout=5, check=True)
        subprocess.run(["tmux", "send-keys", "-t", session, "Enter"], timeout=5, check=True)
        time.sleep(5)
        subprocess.run(
            ["tmux", "send-keys", "-t", session, "Enter"],
            timeout=5,
            check=True,
        )
        return 200, {"status": "cleared", "session": session}
    except (FileNotFoundError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        return 400, {"error": f"clear failed: {e}"}


def _days(period):
    """Parse '7d' -> 7. Defaults to 7, clamps to 1..90."""
    value = str(period or "")[:8]
    match = re.fullmatch(r"(\d{1,3})d?", value)
    n = int(match.group(1)) if match else 7
    return max(1, min(90, n))


def status_payload():
    """Overlay the cached snapshot with authoritative live disk safety state."""
    raw = read_json(STATUS_FILE)
    snapshot_valid = isinstance(raw, dict)
    payload = dict(raw) if snapshot_valid else {}
    if not snapshot_valid:
        payload["snapshot_error"] = (
            "no snapshot yet — run status-snapshot.sh"
            if not os.path.exists(STATUS_FILE)
            else "status snapshot is not a JSON object"
        )
    for field in ("workers", "cron_jobs"):
        value = payload.get(field)
        payload[field] = (
            [item for item in value if isinstance(item, dict)]
            if isinstance(value, list)
            else []
        )

    circuit_value = payload.get("circuit_breaker")
    circuit = dict(circuit_value) if isinstance(circuit_value, dict) else {}
    live_stopped = os.path.isfile(_stop_file())
    circuit["global_stop"] = live_stopped

    def number(mapping, key):
        value = mapping.get(key) if isinstance(mapping, dict) else None
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None

    spend = circuit.get("spend")
    depth = circuit.get("depth")
    weekly = number(spend, "weekly")
    cap = number(spend, "cap")
    current_depth = number(depth, "current")
    max_depth = number(depth, "max")
    spend_tripped = weekly is not None and cap is not None and weekly >= cap
    depth_tripped = (
        current_depth is not None
        and max_depth is not None
        and current_depth >= max_depth
    )
    if live_stopped or spend_tripped or depth_tripped:
        circuit["status"] = "TRIPPED"
    elif snapshot_valid:
        circuit["status"] = "PASS"
    else:
        circuit["status"] = "UNKNOWN"
    payload["circuit_breaker"] = circuit

    generated_at = payload.get("generated_at")
    age_seconds = None
    if isinstance(generated_at, str):
        try:
            generated = datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
            if generated.tzinfo is None:
                generated = generated.replace(tzinfo=timezone.utc)
            age_seconds = max(
                0, int((datetime.now(timezone.utc) - generated).total_seconds())
            )
        except ValueError:
            pass
    payload["snapshot_age_seconds"] = age_seconds
    payload["snapshot_stale"] = (
        age_seconds is None or age_seconds > SNAPSHOT_STALE_SECONDS
    )
    return payload


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
            for line in f:
                line = line.rstrip("\r\n")
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


def list_task_runs(limit=100):
    """Newest Phase 5e task runs with bounded result/check output."""
    out = []
    if not os.path.isdir(TASK_RUN_DIR):
        return out
    for request_id in os.listdir(TASK_RUN_DIR):
        if not _safe_id(request_id):
            continue
        task_dir = os.path.join(TASK_RUN_DIR, request_id)
        if not os.path.isdir(task_dir):
            continue
        request = read_json_object(os.path.join(task_dir, "request.json"), {}) or {}
        state = read_json_object(os.path.join(task_dir, "state.json"), {}) or {}
        result = read_json_object(os.path.join(task_dir, "result.json"), {}) or {}
        try:
            with open(os.path.join(task_dir, "result.md"), encoding="utf-8") as f:
                report = f.read(12000)
        except OSError:
            report = ""
        status = result.get("status") or state.get("status") or "unknown"
        if not isinstance(status, str):
            status = "unknown"
        checks = result.get("checks")
        if not isinstance(checks, list):
            checks = []
        out.append({
            "request_id": request_id,
            "correlation_id": _safe_text(request.get("correlation_id")),
            "title": _safe_text(
                request.get("title") or request.get("ticket_id"), request_id
            ),
            "agent": _safe_text(
                request.get("agent_id") or request.get("agent")
            ),
            "agent_name": _safe_text(request.get("agent_name")),
            "provider_id": _safe_text(request.get("provider_id")),
            "priority": _safe_text(request.get("priority"), "normal"),
            "repository": _safe_text(request.get("repository")),
            "branch": _safe_text(request.get("branch")),
            "summary": str(request.get("summary") or request.get("task") or "")[:1000],
            "status": status,
            "created_at": _safe_text(
                request.get("created_at") or state.get("registered_at")
            ),
            "queued_at": _safe_text(state.get("queued_at")),
            "dispatched_at": _safe_text(state.get("dispatched_at")),
            "dispatching_at": _safe_text(state.get("dispatching_at")),
            "cancelled_at": _safe_text(state.get("cancelled_at")),
            "blocked_at": _safe_text(state.get("blocked_at")),
            "dispatch_failed_at": _safe_text(state.get("dispatch_failed_at")),
            "delivery_failed_at": _safe_text(state.get("delivery_failed_at")),
            "failed_at": _safe_text(state.get("failed_at")),
            "qa_completed_at": _safe_text(state.get("qa_completed_at")),
            "workspace": _safe_text(state.get("workspace")),
            "ticket_id": _safe_id(request.get("ticket_id")),
            "checks": [check for check in checks if isinstance(check, dict)],
            "result": report,
            "status_detail": _safe_text(
                state.get("status_detail") or state.get("detail")
            )[:1000],
            "last_error": _safe_text(state.get("last_error") or state.get("error"))[
                :1000
            ],
        })
    out.sort(
        key=lambda item: _safe_text(item.get("qa_completed_at"))
        or _safe_text(item.get("dispatched_at"))
        or _safe_text(item.get("created_at")),
        reverse=True,
    )
    try:
        bounded_limit = max(1, min(500, int(limit)))
    except (TypeError, ValueError):
        bounded_limit = 100
    return out[:bounded_limit]


def _parse_ticket(path):
    try:
        with open(path, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return None
    if not content.startswith("---\n"):
        return None
    end = content.find("\n---\n", 4)
    if end < 0:
        return None
    fields = {}
    for line in content[4:end].splitlines():
        match = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*?)\s*$", line)
        if not match:
            continue
        value = match.group(2).strip()
        if (
            len(value) >= 2
            and value[0] == value[-1]
            and value[0] in ("'", '"')
        ):
            value = value[1:-1]
        fields[match.group(1)] = value
    body = content[end + 5:]

    def section(heading):
        match = re.search(
            rf"(?ms)^## {re.escape(heading)}\s*$\n(.*?)(?=^## |\Z)",
            body,
        )
        return match.group(1).strip() if match else ""

    ticket_id = fields.get("id") or os.path.splitext(os.path.basename(path))[0]
    if not _safe_id(ticket_id):
        return None
    return {
        **fields,
        "id": ticket_id,
        "path": os.path.realpath(path),
        "goal": section("Goal"),
        "results": section("Results")[:12000],
    }


def list_tickets(limit=200):
    """Phase 5g Markdown tickets, newest files first."""
    out = []
    if not os.path.isdir(TICKET_DIR):
        return out
    root = os.path.realpath(TICKET_DIR)
    for current, _dirs, files in os.walk(root):
        for filename in files:
            if not filename.endswith(".md") or filename.startswith("_"):
                continue
            candidate = os.path.join(current, filename)
            if os.path.islink(candidate):
                continue
            resolved = os.path.realpath(candidate)
            try:
                if os.path.commonpath((root, resolved)) != root:
                    continue
            except ValueError:
                continue
            ticket = _parse_ticket(resolved)
            if ticket:
                out.append(ticket)
    out.sort(
        key=lambda item: (
            item.get("created", ""),
            os.path.getmtime(item["path"]) if os.path.exists(item["path"]) else 0,
        ),
        reverse=True,
    )
    try:
        bounded_limit = max(1, min(500, int(limit)))
    except (TypeError, ValueError):
        bounded_limit = 200
    return out[:bounded_limit]


def _replace_ticket_status(path, status):
    with open(path, encoding="utf-8") as f:
        content = f.read()
    updated, count = re.subn(
        r"(?m)^status:\s*[^\n]*$",
        f"status: {status}",
        content,
        count=1,
    )
    if not count:
        raise ValueError("ticket has no status field")
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(updated)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def review_ticket(body):
    """Record Kevin's explicit review; automation never marks a ticket done."""
    try:
        data = parse_json_object(body)
    except InvalidJsonBody as exc:
        return 400, {"error": str(exc)}
    ticket_id = _safe_id(data.get("ticket_id"))
    decision = str(data.get("decision") or "").strip()
    if not ticket_id or decision not in ("done", "blocked"):
        return 400, {"error": "valid ticket_id and done/blocked decision are required"}
    ticket = next((item for item in list_tickets() if item.get("id") == ticket_id), None)
    if not ticket:
        return 404, {"error": "ticket not found"}
    root = os.path.realpath(TICKET_DIR)
    path = os.path.realpath(ticket["path"])
    try:
        if os.path.commonpath((root, path)) != root:
            return 403, {"error": "ticket path escapes the configured ticket directory"}
    except ValueError:
        return 403, {"error": "ticket path is invalid"}
    if decision == "done" and ticket.get("status") != "pending_review":
        return 409, {"error": "only pending_review tickets can be marked done"}
    try:
        _replace_ticket_status(path, decision)
    except (OSError, ValueError) as exc:
        return 409, {"error": str(exc)}
    append_event(
        f"{uuid.uuid4()}:0",
        "ticket_done" if decision == "done" else "ticket_blocked",
        "mission-control",
        ticket_id,
    )
    return 200, {"status": decision, "ticket_id": ticket_id}


def list_learnings():
    """Return the current Phase 5d file and parsed append-only entries."""
    try:
        with open(LEARNINGS_FILE, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        content = ""
    entries = [line[2:].strip() for line in content.splitlines() if line.startswith("- ")]
    return {
        "path": LEARNINGS_FILE,
        "entries": entries[-100:],
        "count": len(entries),
        "initialized": bool(content),
    }


def add_learning(body):
    """Append one operator-curated learning without automated rewriting."""
    try:
        data = parse_json_object(body)
    except InvalidJsonBody as exc:
        return 400, {"error": str(exc)}
    text = re.sub(r"[\r\n]+", " ", str(data.get("text") or "")).strip()
    tags = re.sub(r"[\r\n\[\]]+", " ", str(data.get("tags") or "general")).strip()
    if not text:
        return 400, {"error": "learning text is required"}
    if len(text) > 1000 or len(tags) > 120:
        return 400, {"error": "learning text or tags exceed the configured limit"}
    os.makedirs(os.path.dirname(LEARNINGS_FILE) or ".", exist_ok=True)
    os.makedirs(os.path.dirname(LEARNINGS_LOCK) or ".", exist_ok=True)
    with open(LEARNINGS_LOCK, "a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if not os.path.exists(LEARNINGS_FILE):
            with open(LEARNINGS_FILE, "w", encoding="utf-8") as f:
                f.write(
                    "# Hermes Compound Learnings\n\n"
                    "> Machine-writeable, human-curated. Kevin decides what stays "
                    "and what becomes a skill.\n\n## Active Learnings\n\n"
                )
        entry = f"{datetime.now(timezone.utc).date().isoformat()} [{tags}] {text}"
        with open(LEARNINGS_FILE, "a", encoding="utf-8") as f:
            f.write(f"- {entry}\n")
            f.flush()
            os.fsync(f.fileno())
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    append_event(f"{uuid.uuid4()}:0", "learning", "mission-control", text[:100])
    return 200, {"status": "recorded", "entry": entry}


def phase5_status():
    runs = list_task_runs()
    tickets = list_tickets()
    learnings = list_learnings()
    return {
        "qa_gate": {
            "ready": os.path.isfile(os.path.join(BASE, "scripts", "qa-gate.sh")),
            "runs": len(runs),
            "awaiting": sum(item.get("status") == "dispatched" for item in runs),
            "failed": sum(item.get("status") == "qa_fail" for item in runs),
        },
        "tickets": {
            "ready": os.path.isdir(TICKET_DIR),
            "path": TICKET_DIR,
            "total": len(tickets),
            "pending_review": sum(
                item.get("status") == "pending_review" for item in tickets
            ),
        },
        "learnings": {
            "ready": learnings["initialized"],
            "path": LEARNINGS_FILE,
            "count": learnings["count"],
        },
    }


class Handler(BaseHTTPRequestHandler):
    def _origin_allowed(self):
        """Allow same-authority browser calls, explicit origins, and origin-less CLI."""
        origin_value = self.headers.get("Origin")
        fetch_site = str(self.headers.get("Sec-Fetch-Site") or "").casefold()
        if origin_value is None:
            return fetch_site != "cross-site"
        origin = _normalize_origin(origin_value)
        if not origin:
            return False
        if origin in ALLOWED_ORIGINS:
            return True
        if fetch_site == "cross-site":
            return False
        host = str(self.headers.get("Host") or "").strip().casefold()
        return bool(host and urlparse(origin).netloc.casefold() == host)

    def _response_origin(self):
        origin_value = self.headers.get("Origin")
        if origin_value is None or not self._origin_allowed():
            return ""
        return _normalize_origin(origin_value)

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        response_origin = self._response_origin()
        if response_origin:
            self.send_header("Access-Control-Allow-Origin", response_origin)
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Vary", "Origin")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        if not self._origin_allowed():
            self._send(403, {"error": "cross-origin request denied"})
            return
        self._send(204, "")

    def do_POST(self):
        path = urlparse(self.path).path
        if not self._origin_allowed():
            self._send(403, {"error": "cross-origin request denied"})
            return
        if self.headers.get_content_type() != "application/json":
            self._send(415, {"error": "Content-Type must be application/json"})
            return
        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            self._send(400, {"error": "invalid Content-Length"})
            return
        if n < 0:
            self._send(400, {"error": "invalid Content-Length"})
            return
        if n > MAX_REQUEST_BODY_BYTES:
            self._send(
                413,
                {
                    "error": (
                        f"request body exceeds the "
                        f"{MAX_REQUEST_BODY_BYTES}-byte limit"
                    )
                },
            )
            return
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
        elif path == "/api/ticket/review":
            self._send(*review_ticket(body))
        elif path == "/api/learnings":
            self._send(*add_learning(body))
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
            self._send(200, status_payload())
        elif path == "/api/events":
            try:
                limit = bounded_query_int(parse_qs(u.query), "limit", 50, 1, 500)
            except InvalidQueryParameter as exc:
                self._send(400, {"error": str(exc)})
            else:
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
        elif path == "/api/task-runs":
            try:
                limit = bounded_query_int(parse_qs(u.query), "limit", 100, 1, 500)
            except InvalidQueryParameter as exc:
                self._send(400, {"error": str(exc)})
            else:
                self._send(200, list_task_runs(limit))
        elif path == "/api/tickets":
            try:
                limit = bounded_query_int(parse_qs(u.query), "limit", 200, 1, 500)
            except InvalidQueryParameter as exc:
                self._send(400, {"error": str(exc)})
            else:
                self._send(200, list_tickets(limit))
        elif path == "/api/learnings":
            self._send(200, list_learnings())
        elif path == "/api/phase5":
            self._send(200, phase5_status())
        elif path == "/api/providers":
            self._send(200, load_provider_registry())
        elif path == "/api/deployments":
            self._send(200, list_deployments())
        elif path == "/api/agent/session":
            qs = parse_qs(u.query)
            session = (qs.get("session") or [""])[0]
            if not session:
                self._send(400, {"error": "session query parameter required"})
            else:
                try:
                    lines = bounded_query_int(qs, "lines", 20, 1, 500)
                except InvalidQueryParameter as exc:
                    self._send(400, {"error": str(exc)})
                else:
                    self._send(*agent_session(session, lines))
        elif path == "/api/notifications":
            try:
                limit = bounded_query_int(parse_qs(u.query), "limit", 50, 1, 500)
            except InvalidQueryParameter as exc:
                self._send(400, {"error": str(exc)})
            else:
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
