#!/usr/bin/env bash
# deploy-approval.sh — durable human approval gate for production deployments.
# Records requests and decisions in the same directories used by Mission Control.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${HERMES_CIRCUIT_BREAKER_CONFIG:-$SCRIPT_DIR/../config/circuit-breaker.yaml}"
DEPLOY_DIR="${HERMES_DEPLOY_REQUEST_DIR:-$HOME/.hermes/deploy-requests}"
APPROVAL_DIR="${HERMES_APPROVAL_DIR:-$HOME/.hermes/approvals}"
NOTIFY="${HERMES_DEPLOY_NOTIFY:-1}"

usage() {
  cat <<'EOF'
deploy-approval.sh — explicit human deployment gate

Usage:
  deploy-approval.sh request --id ID --title TITLE --summary SUMMARY
      [--repository REPO] [--ref REF] [--risk low|medium|high|critical]
      [--checks TEXT] [--rollback TEXT] [--correlation-id ID]
  deploy-approval.sh decide --id ID --decision approve|deny
      [--reason TEXT] [--by OPERATOR]
  deploy-approval.sh notify --id ID
  deploy-approval.sh check --id ID
  deploy-approval.sh status --id ID
  deploy-approval.sh list

Environment:
  HERMES_DEPLOY_REQUEST_DIR       Request directory
  HERMES_APPROVAL_DIR             Decision directory
  HERMES_DEPLOY_APPROVAL_TARGET   Discord target or channel ID
  HERMES_DEPLOY_NOTIFY=0          Print notifications instead of sending

check exit codes: 0=approved, 1=pending, 2=denied, 3=invalid/missing request
EOF
}

die() {
  echo "error: $1" >&2
  exit "${2:-3}"
}

safe_id() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

new_cid() {
  printf '%s:0' "$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
}

yaml_get() {
  { grep -E "^[[:space:]]*$1:" "$2" 2>/dev/null || true; } | head -n1 \
    | sed -E "s/^[[:space:]]*$1:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^\"//; s/\"$//"
}

resolve_target() {
  local target="${HERMES_DEPLOY_APPROVAL_TARGET:-}"
  if [[ -z "$target" ]]; then
    target="$(yaml_get channel_id "$CONFIG")"
  fi
  [[ -n "$target" ]] || die "no Discord approval target configured" 4
  [[ "$target" == *:* ]] || target="discord:$target"
  printf '%s' "$target"
}

log_event() {
  local cid="$1" event="$2" agent="$3" detail="$4"
  bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" \
    --event "$event" --agent "$agent" --detail "$detail" 2>/dev/null || true
}

request_path() {
  printf '%s/%s.json' "$DEPLOY_DIR" "$1"
}

approval_path() {
  printf '%s/%s.json' "$APPROVAL_DIR" "$1"
}

notify_request() {
  local id="$1" path message target
  path="$(request_path "$id")"
  [[ -f "$path" ]] || die "deployment request not found: $id"
  message="$(python3 - "$path" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    item = json.load(handle)

lines = [
    "🚦 **DEPLOYMENT APPROVAL REQUIRED**",
    f"**ID:** `{item['id']}`",
    f"**Title:** {item['title']}",
]
if item.get("repository"):
    lines.append(f"**Repository:** `{item['repository']}`")
if item.get("ref"):
    lines.append(f"**Ref:** `{item['ref']}`")
lines.extend([
    f"**Risk:** {item.get('risk', 'review').upper()}",
    f"**Summary:** {item['summary']}",
])
if item.get("checks"):
    lines.append(f"**Checks:** {item['checks']}")
if item.get("rollback"):
    lines.append(f"**Rollback:** {item['rollback']}")
lines.extend([
    "",
    f"Reply `approve deploy {item['id']}`",
    f"or `deny deploy {item['id']} <reason>`.",
    f"Reply `notify deploy {item['id']}` to repeat this summary.",
    "",
    "No deployment may begin until the durable approval record exists.",
])
print("\n".join(lines))
PY
)"

  if [[ "$NOTIFY" == "0" ]]; then
    printf '%s\n' "$message"
    return 0
  fi

  command -v hermes >/dev/null 2>&1 || die "hermes CLI not found; request remains pending" 4
  target="$(resolve_target)"
  if ! hermes send --quiet --to "$target" "$message"; then
    die "Discord notification failed; request remains pending" 4
  fi
  log_event "$(new_cid)" notify deploy-approval "deployment approval requested: $id"
}

cmd_request() {
  local id="" title="" summary="" repository="" ref="" risk="medium"
  local checks="" rollback="" cid=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)             id="${2:?--id needs a value}"; shift 2 ;;
      --title)          title="${2:?--title needs a value}"; shift 2 ;;
      --summary)        summary="${2:?--summary needs a value}"; shift 2 ;;
      --repository)     repository="${2:?--repository needs a value}"; shift 2 ;;
      --ref)            ref="${2:?--ref needs a value}"; shift 2 ;;
      --risk)           risk="${2:?--risk needs a value}"; shift 2 ;;
      --checks)         checks="${2:?--checks needs a value}"; shift 2 ;;
      --rollback)       rollback="${2:?--rollback needs a value}"; shift 2 ;;
      --correlation-id) cid="${2:?--correlation-id needs a value}"; shift 2 ;;
      *) die "unknown request argument '$1'" ;;
    esac
  done
  safe_id "$id" || die "--id must use letters, numbers, dots, underscores, or hyphens"
  [[ -n "$title" && -n "$summary" ]] || die "--title and --summary are required"
  case "$risk" in low|medium|high|critical) ;; *) die "risk must be low, medium, high, or critical" ;; esac
  cid="${cid:-$(new_cid)}"

  mkdir -p "$DEPLOY_DIR" "$APPROVAL_DIR"
  exec 9>"$DEPLOY_DIR/.approval.lock"
  flock 9
  local request approval
  request="$(request_path "$id")"
  approval="$(approval_path "$id")"
  [[ ! -e "$request" ]] || die "deployment request already exists: $id"
  [[ ! -e "$approval" ]] || die "deployment decision already exists: $id"

  python3 - "$request" "$id" "$title" "$summary" "$repository" "$ref" "$risk" \
    "$checks" "$rollback" "$cid" "${USER:-operator}" <<'PY'
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import uuid

path = Path(sys.argv[1])
record = {
    "id": sys.argv[2],
    "title": sys.argv[3],
    "summary": sys.argv[4],
    "repository": sys.argv[5],
    "ref": sys.argv[6],
    "risk": sys.argv[7],
    "checks": sys.argv[8],
    "rollback": sys.argv[9],
    "correlation_id": sys.argv[10],
    "requested_by": sys.argv[11],
    "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "status": "pending",
}
temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
os.replace(temporary, path)
PY

  log_event "$cid" deploy_request deploy-approval "$id: $title"
  flock -u 9
  notify_request "$id"
  printf 'deployment request pending: %s\n' "$id"
}

cmd_decide() {
  local id="" decision="" reason="" by="${USER:-operator}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)       id="${2:?--id needs a value}"; shift 2 ;;
      --decision) decision="${2:?--decision needs a value}"; shift 2 ;;
      --reason)   reason="${2:?--reason needs a value}"; shift 2 ;;
      --by)       by="${2:?--by needs a value}"; shift 2 ;;
      *) die "unknown decide argument '$1'" ;;
    esac
  done
  safe_id "$id" || die "invalid deployment id"
  case "$decision" in approve|deny) ;; *) die "decision must be approve or deny" ;; esac

  mkdir -p "$DEPLOY_DIR" "$APPROVAL_DIR"
  exec 9>"$DEPLOY_DIR/.approval.lock"
  flock 9
  local request approval result code
  request="$(request_path "$id")"
  approval="$(approval_path "$id")"
  [[ -f "$request" ]] || die "deployment request not found: $id"

  set +e
  result="$(python3 - "$request" "$approval" "$decision" "$reason" "$by" <<'PY'
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys
import uuid

request_path = Path(sys.argv[1])
approval_path = Path(sys.argv[2])
decision, reason, decided_by = sys.argv[3:]
with open(request_path, encoding="utf-8") as handle:
    request = json.load(handle)

if approval_path.exists():
    with open(approval_path, encoding="utf-8") as handle:
        existing = json.load(handle)
    if existing.get("decision") != decision:
        print(
            f"error: deployment {request['id']} already has decision "
            f"{existing.get('decision')}; refusing conflicting {decision}",
            file=sys.stderr,
        )
        raise SystemExit(2)
    print(json.dumps({"status": decision, "deployment_id": request["id"], "idempotent": True}))
    raise SystemExit(0)

record = {
    "deployment_id": request["id"],
    "decision": decision,
    "reason": reason,
    "decided_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "decided_by": decided_by,
}
temporary = approval_path.with_name(f".{approval_path.name}.{uuid.uuid4().hex}.tmp")
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(record, handle, indent=2)
    handle.write("\n")
os.replace(temporary, approval_path)
print(json.dumps({"status": decision, "deployment_id": request["id"], "idempotent": False}))
PY
)"
  code=$?
  set -e
  [[ $code -eq 0 ]] || exit "$code"

  if [[ "$(python3 -c 'import json,sys; print(str(json.load(sys.stdin)["idempotent"]).lower())' <<<"$result")" == "false" ]]; then
    log_event "$(new_cid)" "$decision" "$by" "deployment $id"
  fi
  printf '%s\n' "$result"
}

cmd_check() {
  local id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="${2:?--id needs a value}"; shift 2 ;;
      *) die "unknown check argument '$1'" ;;
    esac
  done
  safe_id "$id" || die "invalid deployment id"
  python3 - "$(request_path "$id")" "$(approval_path "$id")" <<'PY'
import json
from pathlib import Path
import sys

request_path, approval_path = map(Path, sys.argv[1:])
if not request_path.exists():
    print(json.dumps({"status": "invalid", "error": "deployment request not found"}))
    raise SystemExit(3)
if not approval_path.exists():
    print(json.dumps({"status": "pending"}))
    raise SystemExit(1)
with open(approval_path, encoding="utf-8") as handle:
    decision = json.load(handle)
print(json.dumps(decision))
raise SystemExit(0 if decision.get("decision") == "approve" else 2)
PY
}

cmd_status() {
  local id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id) id="${2:?--id needs a value}"; shift 2 ;;
      *) die "unknown status argument '$1'" ;;
    esac
  done
  safe_id "$id" || die "invalid deployment id"
  python3 - "$(request_path "$id")" "$(approval_path "$id")" <<'PY'
import json
from pathlib import Path
import sys

request_path, approval_path = map(Path, sys.argv[1:])
if not request_path.exists():
    print(json.dumps({"error": "deployment request not found"}))
    raise SystemExit(3)
with open(request_path, encoding="utf-8") as handle:
    request = json.load(handle)
decision = None
if approval_path.exists():
    with open(approval_path, encoding="utf-8") as handle:
        decision = json.load(handle)
print(json.dumps({"request": request, "decision": decision}, indent=2))
PY
}

cmd_list() {
  python3 - "$DEPLOY_DIR" "$APPROVAL_DIR" <<'PY'
import json
from pathlib import Path
import sys

deploy_dir, approval_dir = map(Path, sys.argv[1:])
pending = []
if deploy_dir.is_dir():
    for path in deploy_dir.glob("*.json"):
        if (approval_dir / path.name).exists():
            continue
        try:
            with open(path, encoding="utf-8") as handle:
                pending.append(json.load(handle))
        except (OSError, ValueError):
            continue
pending.sort(key=lambda item: item.get("created_at", ""), reverse=True)
print(json.dumps(pending, indent=2))
PY
}

command="${1:-}"
shift || true
case "$command" in
  request) cmd_request "$@" ;;
  decide)  cmd_decide "$@" ;;
  notify)
    [[ "${1:-}" == "--id" && -n "${2:-}" && $# -eq 2 ]] || die "notify requires --id ID"
    safe_id "$2" || die "invalid deployment id"
    notify_request "$2"
    ;;
  check)   cmd_check "$@" ;;
  status)  cmd_status "$@" ;;
  list)    [[ $# -eq 0 ]] || die "list takes no arguments"; cmd_list ;;
  -h|--help|help|"") usage ;;
  *) die "unknown command '$command'" ;;
esac
