#!/usr/bin/env bash
# global-stop.sh — Phase 2: global stop flag (Kevin's emergency brake)
# Disk-based flag survives a watchdog restart — do not replace with in-memory state.
#
# Exit codes: 0 = stopped (check) / success, 1 = running (check) / usage error
set -euo pipefail

FLAG_FILE="${HERMES_STOP_FILE:-$HOME/.hermes/stop}"
STALE_HOURS=24

usage() {
  cat <<EOF
global-stop.sh — set/clear/check the global stop flag

Usage:
  global-stop.sh set [reason]   Write flag ($FLAG_FILE) with timestamp+reason
  global-stop.sh clear          Remove the flag
  global-stop.sh check          Exit 0 STOPPED / exit 1 RUNNING (for 'if')
  global-stop.sh status         JSON: status, timestamp, reason

Flag auto-clears if older than ${STALE_HOURS}h (stale watchdog leftover).
Env: HERMES_STOP_FILE overrides flag path (default ~/.hermes/stop)
EOF
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# read a "key: value" field from the flag file
field() { sed -n "s/^$1: //p" "$FLAG_FILE" 2>/dev/null | head -n1; }

# Auto-clear if the flag is older than STALE_HOURS. Warns on stderr. Returns 0 if cleared.
expire_if_stale() {
  [[ -f "$FLAG_FILE" ]] || return 1
  local age_s
  age_s=$(( $(date +%s) - $(date -r "$FLAG_FILE" +%s) ))
  if [[ "$age_s" -gt $((STALE_HOURS * 3600)) ]]; then
    echo "warning: stop flag older than ${STALE_HOURS}h — auto-clearing stale flag" >&2
    rm -f "$FLAG_FILE"
    return 0
  fi
  return 1
}

cmd="${1:-}"
case "$cmd" in
  set)
    reason="${2:-Manual stop — Kevin requested}"
    {
      echo "stopped_at: $(now_utc)"
      echo "reason: $reason"
      echo "set_by: ${USER:-kevin}"
    } > "$FLAG_FILE"
    echo "STOPPED: flag set at $FLAG_FILE"
    ;;
  clear)
    rm -f "$FLAG_FILE"
    echo "RUNNING: flag cleared"
    ;;
  check)
    expire_if_stale || true
    if [[ -f "$FLAG_FILE" ]]; then
      echo "STOPPED"; exit 0
    else
      echo "RUNNING"; exit 1
    fi
    ;;
  status)
    expire_if_stale || true
    if [[ -f "$FLAG_FILE" ]]; then
      printf '{"status": "STOPPED", "stopped_at": "%s", "reason": "%s", "set_by": "%s"}\n' \
        "$(field stopped_at)" "$(field reason)" "$(field set_by)"
    else
      printf '{"status": "RUNNING", "stopped_at": null, "reason": null, "set_by": null}\n'
    fi
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
