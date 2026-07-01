#!/usr/bin/env bash
# agent-event.sh — Phase 5a: append-only structured event log.
# Called by Hermes at dispatch/complete/fail/circuit_break boundaries.
# Format: <ts>|<correlation_id>|<event>|<agent>|<detail>   (pipe-separated, one line/event)
#
# Exit codes: 0 success, 1 usage/error
set -euo pipefail

LOG_FILE="${HERMES_EVENT_LOG:-$HOME/.hermes/logs/agent-events.log}"

# event types (informational — not enforced): dispatch complete fail qa_pass qa_fail
#   circuit_break deploy approve deny stop start

usage() {
  cat <<EOF
agent-event.sh — structured agent event log

Usage:
  agent-event.sh log --correlation-id ID --event TYPE --agent NAME [--detail "..."]
  agent-event.sh recent [--limit N]        Last N events (default 20)
  agent-event.sh since <ISO-8601-ts>       Events with timestamp >= ts

Log: $LOG_FILE   (env HERMES_EVENT_LOG)
EOF
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# strip pipes/newlines so one event stays one line
clean() { echo "${1//[|$'\n\r']/ }"; }

cmd="${1:-}"
shift || true

case "$cmd" in
  log)
    cid="" event="" agent="" detail=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --correlation-id) cid="$2"; shift 2 ;;
        --event)          event="$2"; shift 2 ;;
        --agent)          agent="$2"; shift 2 ;;
        --detail)         detail="$2"; shift 2 ;;
        *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
      esac
    done
    [[ -n "$cid" && -n "$event" && -n "$agent" ]] || {
      echo "error: --correlation-id, --event, --agent required" >&2; exit 1; }
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "$(now_utc)|$(clean "$cid")|$(clean "$event")|$(clean "$agent")|$(clean "$detail")" >> "$LOG_FILE"
    ;;

  recent)
    limit=20
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --limit) limit="$2"; shift 2 ;;
        *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
      esac
    done
    [[ -f "$LOG_FILE" ]] || { echo "No events yet" >&2; exit 0; }
    tail -n "$limit" "$LOG_FILE"
    ;;

  since)
    ts="${1:?since needs an ISO-8601 timestamp}"
    [[ -f "$LOG_FILE" ]] || { echo "No events yet" >&2; exit 0; }
    # ISO 8601 sorts lexicographically → plain string compare on the timestamp field
    awk -F'|' -v since="$ts" '$1 >= since' "$LOG_FILE"
    ;;

  -h|--help|help|"")
    usage
    ;;
  *)
    echo "error: unknown command '$cmd'" >&2
    usage >&2
    exit 1
    ;;
esac
