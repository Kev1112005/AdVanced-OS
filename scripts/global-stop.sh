#!/usr/bin/env bash
# global-stop.sh — Phase 2: global stop flag (Kevin's emergency brake)
# Disk-based flag survives a watchdog restart — do not replace with in-memory state.
#
# Exit codes: 0 = stopped (check) / success, 1 = running (check) / usage error
set -euo pipefail

FLAG_FILE="${HERMES_STOP_FILE:-$HOME/.hermes/stop}"

usage() {
  cat <<EOF
global-stop.sh — set/clear/check the global stop flag

Usage:
  global-stop.sh set [reason]   Write flag ($FLAG_FILE) with timestamp+reason
  global-stop.sh clear          Remove the flag
  global-stop.sh check          Exit 0 STOPPED / exit 1 RUNNING (for 'if')
  global-stop.sh status         JSON: status, timestamp, reason

The flag never expires. Only an explicit clear releases the stop.
Env: HERMES_STOP_FILE overrides flag path (default ~/.hermes/stop)
EOF
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

clean_field() {
  local value="${1:-}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  printf '%s' "$value"
}

cmd="${1:-}"
case "$cmd" in
  set)
    reason="$(clean_field "${2:-Manual stop — Kevin requested}")"
    set_by="$(clean_field "${USER:-kevin}")"
    mkdir -p "$(dirname "$FLAG_FILE")"
    umask 077
    temporary="$(mktemp "${FLAG_FILE}.tmp.XXXXXX")"
    trap 'rm -f "${temporary:-}"' EXIT
    {
      printf 'stopped_at: %s\n' "$(now_utc)"
      printf 'reason: %s\n' "$reason"
      printf 'set_by: %s\n' "$set_by"
    } > "$temporary"
    mv -f "$temporary" "$FLAG_FILE"
    trap - EXIT
    echo "STOPPED: flag set at $FLAG_FILE"
    ;;
  clear)
    rm -f "$FLAG_FILE"
    echo "RUNNING: flag cleared"
    ;;
  check)
    if [[ -f "$FLAG_FILE" ]]; then
      echo "STOPPED"; exit 0
    else
      echo "RUNNING"; exit 1
    fi
    ;;
  status)
    if [[ -f "$FLAG_FILE" ]]; then
      python3 - "$FLAG_FILE" <<'PY'
import json
import pathlib
import sys

fields = {}
for line in pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    key, separator, value = line.partition(": ")
    if separator and key in {"stopped_at", "reason", "set_by"} and key not in fields:
        fields[key] = value
print(json.dumps({
    "status": "STOPPED",
    "stopped_at": fields.get("stopped_at") or None,
    "reason": fields.get("reason") or None,
    "set_by": fields.get("set_by") or None,
}))
PY
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
