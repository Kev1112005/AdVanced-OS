#!/usr/bin/env bash
# deploy-approval.sh — durable human approval gate for production deployments.
# Records requests and decisions in the same directories used by Mission Control.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
APPROVAL_HELPER="$SCRIPT_DIR/../server/deployment_approval.py"
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

Exit codes:
  check:  0=approved, 1=pending, 2=denied, 3=invalid/missing/corrupt state
  decide: 0=recorded/idempotent, 3=invalid state, 5=conflicting decision
  notify: 0=delivered/printed, 4=delivery/configuration failure

request exits 0 once the durable request exists. Notification failure is
reported as a warning and can be retried with notify.
EOF
}

die() {
  echo "error: $1" >&2
  exit "${2:-3}"
}

safe_id() {
  python3 "$APPROVAL_HELPER" validate-id "$1" >/dev/null 2>&1
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

  python3 "$APPROVAL_HELPER" request \
    --deploy-dir "$DEPLOY_DIR" \
    --approval-dir "$APPROVAL_DIR" \
    --id "$id" \
    --title "$title" \
    --summary "$summary" \
    --repository "$repository" \
    --ref "$ref" \
    --risk "$risk" \
    --checks "$checks" \
    --rollback "$rollback" \
    --correlation-id "$cid" \
    --requested-by "${USER:-operator}" >/dev/null

  log_event "$cid" deploy_request deploy-approval "$id: $title"
  if ! (notify_request "$id"); then
    echo "warning: deployment request $id is durable but notification failed; retry with notify --id $id" >&2
  fi
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

  local result code
  set +e
  result="$(python3 "$APPROVAL_HELPER" decide \
    --deploy-dir "$DEPLOY_DIR" \
    --approval-dir "$APPROVAL_DIR" \
    --id "$id" \
    --decision "$decision" \
    --reason "$reason" \
    --by "$by")"
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
  python3 "$APPROVAL_HELPER" check \
    --deploy-dir "$DEPLOY_DIR" \
    --approval-dir "$APPROVAL_DIR" \
    --id "$id"
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
  python3 "$APPROVAL_HELPER" status \
    --deploy-dir "$DEPLOY_DIR" \
    --approval-dir "$APPROVAL_DIR" \
    --id "$id"
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
