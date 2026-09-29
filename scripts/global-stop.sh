#!/usr/bin/env bash
# global-stop.sh — Phase 2: global stop flag (Kevin's emergency brake)
# Disk-based flag survives a watchdog restart — do not replace with in-memory state.
#
# Exit codes: 0 = stopped (check) / success, 1 = running (check) / usage error
set -euo pipefail

FLAG_FILE="${HERMES_STOP_FILE:-$HOME/.hermes/stop}"
STOP_LOCK="${HERMES_STOP_LOCK:-$HOME/.hermes/global-stop.lock}"

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
     HERMES_STOP_LOCK overrides the mutation lock (default ~/.hermes/global-stop.lock)
EOF
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

clean_field() {
  local value="${1:-}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  printf '%s' "$value"
}

node_exists() {
  [[ -e "$FLAG_FILE" || -L "$FLAG_FILE" ]]
}

valid_flag() {
  [[ -f "$FLAG_FILE" && ! -L "$FLAG_FILE" ]]
}

fsync_parent() {
  python3 - "$(dirname "$1")" <<'PY'
import os
import sys

if not os.path.isdir(sys.argv[1]):
    raise SystemExit(0)
descriptor = os.open(sys.argv[1], os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
try:
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

acquire_mutation_lock() {
  if [[ "${HERMES_STOP_LOCK_HELD:-0}" == 1 ]]; then
    return
  fi
  mkdir -p "$(dirname "$STOP_LOCK")"
  exec 9>"$STOP_LOCK"
  flock 9
}

cmd="${1:-}"
case "$cmd" in
  set)
    acquire_mutation_lock
    if node_exists && ! valid_flag; then
      echo "error: refusing to replace invalid stop node: $FLAG_FILE" >&2
      exit 1
    fi
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
    fsync_parent "$FLAG_FILE"
    trap - EXIT
    echo "STOPPED: flag set at $FLAG_FILE"
    ;;
  clear)
    acquire_mutation_lock
    if [[ -d "$FLAG_FILE" && ! -L "$FLAG_FILE" ]]; then
      echo "error: stop node is a directory; remove it explicitly after inspection" >&2
      exit 1
    fi
    rm -f "$FLAG_FILE"
    fsync_parent "$FLAG_FILE"
    echo "RUNNING: flag cleared"
    ;;
  check)
    if node_exists; then
      echo "STOPPED"; exit 0
    else
      echo "RUNNING"; exit 1
    fi
    ;;
  status)
    if valid_flag; then
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
    elif node_exists; then
      python3 - "$FLAG_FILE" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if path.is_symlink():
    kind = "symlink"
elif path.is_dir():
    kind = "directory"
else:
    kind = "non-regular node"
print(json.dumps({
    "status": "STOPPED",
    "stopped_at": None,
    "reason": f"Invalid stop node ({kind}) blocks dispatch until explicitly resolved",
    "set_by": None,
    "invalid": True,
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
