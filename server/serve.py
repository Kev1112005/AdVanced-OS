#!/usr/bin/env python3
"""Mission Control HTTP server — Phase 3.

Serves the dashboard and a few read-only JSON endpoints backed by flat files.
Python stdlib only: no Flask, no deps. Bind 0.0.0.0:3001 for LAN access.

Endpoints:
  GET /                  -> public/index.html
  GET /api/status        -> ~/.hermes/status/current.json (raw passthrough)
  GET /api/events?limit  -> last N lines of agent-events.log as JSON array
  GET /api/cost/summary  -> weekly cost rollup parsed from cost-log.csv
  GET /api/health        -> {"status":"ok","uptime":<seconds>}
"""
import csv
import json
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

STATUS_FILE = os.environ.get("HERMES_STATUS_FILE", f"{HOME}/.hermes/status/current.json")
EVENT_LOG = os.environ.get("HERMES_EVENT_LOG", f"{HOME}/.hermes/logs/agent-events.log")
# COST_LOG = os.environ.get("HERMES_COST_LOG", f"{HOME}/.hermes/logs/cost-log.csv")  # cost tracking disabled
REQ_DIR = os.environ.get("HERMES_REQUESTS_DIR", f"{HOME}/.hermes/requests")
NOTIF_LOG = os.environ.get("HERMES_NOTIF_LOG", f"{HOME}/.hermes/notifications.log")
# CAP = float(os.environ.get("HERMES_WEEKLY_CAP", "20.0"))  # cost tracking disabled
PORT = int(os.environ.get("MISSION_CONTROL_PORT", "3001"))

START = time.time()


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
    agent = str(data.get("agent", "")).strip()
    task = str(data.get("task", "")).strip()
    if not agent or not task:
        return 400, {"error": "agent and task are required"}
    KNOWN_AGENTS = {"claude-belial", "claude-obsoletebot", "claude-remote-control", "ezekiel", "sammael"}
    if agent not in KNOWN_AGENTS:
        return 400, {"error": f"unknown agent '{agent}'. known agents: {', '.join(sorted(KNOWN_AGENTS))}"}
    priority = str(data.get("priority", "normal")).strip() or "normal"

    rid = str(uuid.uuid4())
    # ponytail: correlation-id.sh emits exactly "<uuid>:0" for a root dispatch;
    # replicated inline to skip a subprocess per request.
    cid = f"{rid}:0"
    req = {"request_id": rid, "correlation_id": cid, "agent": agent,
           "task": task, "priority": priority,
           "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
    os.makedirs(REQ_DIR, exist_ok=True)
    with open(os.path.join(REQ_DIR, f"{rid}.json"), "w", encoding="utf-8") as f:
        json.dump(req, f, indent=2)
    return 200, {"status": "queued", "request_id": rid, "correlation_id": cid}


def _session_alive(session):
    r = subprocess.run(["tmux", "has-session", "-t", session],
                       capture_output=True, timeout=5)
    return r.returncode == 0


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
        elif path == "/api/agent/send":
            self._send(*send_keys(body))
        elif path == "/api/agent/clear":
            self._send(*clear_session(body))
        else:
            self._send(404, {"error": "not found"})

    def _file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                self._send(200, f.read().decode("utf-8", "replace"), ctype)
        except FileNotFoundError:
            self._send(404, {"error": f"not found: {os.path.basename(path)}"})

    def do_GET(self):
        u = urlparse(self.path)
        path = u.path
        if path in ("/", "/index.html"):
            self._file(os.path.join(PUBLIC, "index.html"), "text/html; charset=utf-8")
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
        httpd.shutdown()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)
    print(f"Mission Control on http://0.0.0.0:{PORT}  (serving {PUBLIC})")
    httpd.serve_forever()


if __name__ == "__main__":
    main()
