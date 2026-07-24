#!/usr/bin/env bash
# ticket-scan.sh — Phase 5g report-only async ticket intake.
#
# Fresh Markdown tickets are claimed exactly once and converted into durable
# serial-gate requests. Only explicitly allowed report-only agents may receive
# them. QA must capture a result, and Kevin reviews before a ticket becomes done.
#
# Usage:
#   ticket-scan.sh init
#   ticket-scan.sh scan
#   ticket-scan.sh list
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICKET_DIR="${HERMES_TICKET_DIR:-$HOME/vaults/kevin/tickets}"
REQ_DIR="${HERMES_REQUESTS_DIR:-$HOME/.hermes/requests}"
DEFAULT_AGENT="${HERMES_TICKET_AGENT:-ezekiel}"
ALLOWED_AGENTS="${HERMES_TICKET_AGENTS:-ezekiel}"
LEARNINGS_FILE="${HERMES_LEARNINGS_FILE:-$HOME/hermes-learnings.md}"
LOCK_FILE="${HERMES_TICKET_LOCK:-$HOME/.hermes/ticket-scan.lock}"

init_surface() {
  mkdir -p "$TICKET_DIR" "$(dirname "$LOCK_FILE")"
  if [[ ! -f "$TICKET_DIR/_README.md" ]]; then
    {
      printf '# Hermes Ticket Surface\n\n'
      printf 'Create a Markdown file with YAML frontmatter and `status: fresh`.\n'
      printf 'Only `mode: report-only` tickets are admitted automatically. '
      printf 'Kevin must review every result before it becomes `done`.\n\n'
      printf 'See `%s` for the complete schema.\n' \
        "$SCRIPT_DIR/../docs/references/ticket-schema.md"
    } > "$TICKET_DIR/_README.md"
  fi
}

case "${1:-scan}" in
  init)
    init_surface
    echo "$TICKET_DIR"
    ;;

  scan)
    init_surface
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0

    # A persistent stop pauses both intake and delivery. The dispatch-depth and
    # spend checks are repeated per admitted ticket below.
    if bash "$SCRIPT_DIR/global-stop.sh" check >/dev/null 2>&1; then
      echo '{"claimed":0,"status":"global_stop"}'
      exit 0
    fi

    TICKET_DIR="$TICKET_DIR" REQ_DIR="$REQ_DIR" DEFAULT_AGENT="$DEFAULT_AGENT" \
      ALLOWED_AGENTS="$ALLOWED_AGENTS" LEARNINGS_FILE="$LEARNINGS_FILE" \
      SCRIPT_DIR="$SCRIPT_DIR" python3 - <<'PY'
import json
import os
import pathlib
import re
import subprocess
import tempfile
import uuid
from datetime import datetime, timezone

ticket_root = pathlib.Path(os.environ["TICKET_DIR"]).expanduser().resolve()
request_root = pathlib.Path(os.environ["REQ_DIR"]).expanduser()
default_agent = os.environ["DEFAULT_AGENT"].strip()
allowed_agents = {
    value.strip() for value in os.environ["ALLOWED_AGENTS"].split(",") if value.strip()
}
script_dir = pathlib.Path(os.environ["SCRIPT_DIR"])
learnings_path = pathlib.Path(os.environ["LEARNINGS_FILE"]).expanduser()


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ticket(content):
    if not content.startswith("---\n"):
        return {}, content
    end = content.find("\n---\n", 4)
    if end < 0:
        return {}, content
    fields = {}
    for line in content[4:end].splitlines():
        match = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*?)\s*$", line)
        if not match:
            continue
        value = match.group(2).strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        fields[match.group(1)] = value
    return fields, content[end + 5:]


def section(body, heading):
    match = re.search(
        rf"(?ms)^## {re.escape(heading)}\s*$\n(.*?)(?=^## |\Z)",
        body,
    )
    return match.group(1).strip() if match else ""


def update_frontmatter(content, replacements):
    updated = content
    for key, value in replacements.items():
        updated, count = re.subn(
            rf"(?m)^{re.escape(key)}:\s*[^\n]*$",
            f"{key}: {value}",
            updated,
            count=1,
        )
        if not count:
            marker = updated.find("\n---\n", 4)
            if marker >= 0:
                updated = updated[:marker] + f"\n{key}: {value}" + updated[marker:]
    return updated


def atomic_text(path, text):
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def breaker_passes(cid):
    result = subprocess.run(
        [
            "bash",
            str(script_dir / "circuit-breaker.sh"),
            "check",
            "--correlation-id",
            cid,
        ],
        capture_output=True,
        timeout=15,
        check=False,
    )
    return result.returncode == 0


try:
    learnings = learnings_path.read_text(encoding="utf-8")[-12000:]
except OSError:
    learnings = ""

request_root.mkdir(parents=True, exist_ok=True)
claimed = []
blocked = []
for discovered in sorted(ticket_root.rglob("*.md")):
    if discovered.name.startswith("_") or discovered.is_symlink():
        continue
    try:
        path = discovered.resolve()
        path.relative_to(ticket_root)
    except (OSError, ValueError):
        continue
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        continue
    fields, body = parse_ticket(content)
    if fields.get("status") != "fresh":
        continue

    ticket_id = fields.get("id") or path.stem
    if not re.fullmatch(r"[A-Za-z0-9._:-]+", ticket_id):
        blocked.append({"path": str(path), "error": "invalid ticket id"})
        continue
    if fields.get("mode", "report-only") != "report-only":
        blocked.append({"id": ticket_id, "error": "only report-only tickets are admitted"})
        continue
    agent = fields.get("agent") or default_agent
    if agent not in allowed_agents:
        blocked.append({"id": ticket_id, "error": f"agent '{agent}' is not allowed"})
        continue
    priority = fields.get("priority", "normal")
    if priority not in {"low", "normal", "high", "critical", "medium"}:
        blocked.append({"id": ticket_id, "error": "invalid priority"})
        continue
    if priority == "medium":
        priority = "normal"

    request_id = str(uuid.uuid4())
    cid = f"{request_id}:0"
    if not breaker_passes(cid):
        blocked.append({"id": ticket_id, "error": "circuit breaker blocked intake"})
        continue

    goal = section(body, "Goal")
    criteria_text = section(body, "Acceptance Criteria")
    criteria = [
        re.sub(r"^\s*[-*]\s*(?:\[[ xX]\]\s*)?", "", line).strip()
        for line in criteria_text.splitlines()
        if re.match(r"^\s*[-*]", line)
    ]
    result_file = f"/tmp/hermes-result-{request_id}.md"
    task_parts = [
        f"# Report-only ticket: {ticket_id}",
        f"Source ticket: {path}",
        body.strip(),
        (
            "## Delivery Protocol\n"
            "This is report-only work. Do not deploy, message third parties, mutate "
            "cron, or make external state changes. Write your final report to "
            f"`{result_file}`, then signal Hermes asynchronously with:\n\n"
            f"`~/.hermes/scripts/hermes-request.sh qa \"{request_id}\" "
            f"--result-file \"{result_file}\" --correlation-id \"{cid}\"`\n\n"
            "The command returns immediately. Kevin reviews the captured result before "
            "the ticket can become done."
        ),
    ]
    if learnings.strip():
        task_parts.insert(
            1,
            "## Relevant Hermes Learnings\n" + learnings.strip(),
        )
    request = {
        "request_id": request_id,
        "correlation_id": cid,
        "type": "ticket",
        "agent": agent,
        "agent_id": agent,
        "agent_name": agent,
        "title": goal.splitlines()[0][:120] if goal else ticket_id,
        "task": "\n\n".join(part for part in task_parts if part),
        "priority": priority,
        "approval_policy": "no_deploy",
        "acceptance_criteria": criteria,
        "qa_checks": [{"type": "result_present"}],
        "ticket_id": ticket_id,
        "source_ticket": str(path),
        "created_at": now(),
    }
    request_path = request_root / f"{request_id}.json"
    atomic_text(request_path, json.dumps(request, indent=2) + "\n")
    atomic_text(
        path,
        update_frontmatter(content, {"status": "claimed", "owner": agent}),
    )
    claimed.append({
        "ticket_id": ticket_id,
        "request_id": request_id,
        "agent": agent,
    })

print(json.dumps({"claimed": len(claimed), "tickets": claimed, "blocked": blocked}))
PY
    ;;

  list)
    init_surface
    TICKET_DIR="$TICKET_DIR" python3 - <<'PY'
import json
import os
import pathlib
import re

root = pathlib.Path(os.environ["TICKET_DIR"]).expanduser().resolve()
out = []
for discovered in sorted(root.rglob("*.md")):
    if discovered.name.startswith("_") or discovered.is_symlink():
        continue
    try:
        path = discovered.resolve()
        path.relative_to(root)
    except (OSError, ValueError):
        continue
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        continue
    if not content.startswith("---\n"):
        continue
    end = content.find("\n---\n", 4)
    if end < 0:
        continue
    fields = {}
    for line in content[4:end].splitlines():
        match = re.match(r"^([A-Za-z][A-Za-z0-9_-]*):\s*(.*?)\s*$", line)
        if match:
            value = match.group(2).strip().strip("\"'")
            fields[match.group(1)] = value
    body = content[end + 5:]
    goal_match = re.search(r"(?ms)^## Goal\s*$\n(.*?)(?=^## |\Z)", body)
    result_match = re.search(r"(?ms)^## Results\s*$\n(.*?)(?=^## |\Z)", body)
    out.append({
        **fields,
        "id": fields.get("id") or path.stem,
        "path": str(path),
        "goal": goal_match.group(1).strip() if goal_match else "",
        "results": result_match.group(1).strip() if result_match else "",
    })
print(json.dumps(out))
PY
    ;;

  -h|--help|help|"")
    sed -n '2,12p' "$0" | sed 's/^# \?//'
    ;;

  *)
    echo "error: unknown command '${1:-}'" >&2
    exit 2
    ;;
esac
