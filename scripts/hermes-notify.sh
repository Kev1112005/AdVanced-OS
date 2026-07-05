#!/usr/bin/env bash
# hermes-notify.sh — Phase 1a: fire-and-forget notification from any worker to Kevin.
# Appends one line to ~/.hermes/notifications.log; notification-tail.sh delivers it.
# This is the pure logging primitive — no circuit-breaker gate, no dispatch. (Use
# `hermes-request notify` if you want it to go through the breaker + request queue.)
#
# Usage:
#   hermes-notify "<message>" [--level info|warn|alert|critical] [--source <name>]
#
# Exit codes: 0=logged  1=usage error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIF_LOG="${HERMES_NOTIF_LOG:-$HOME/.hermes/notifications.log}"

die() { echo "error: $1" >&2; exit 1; }

[[ $# -ge 1 && -n "${1:-}" ]] || die "usage: hermes-notify \"<message>\" [--level L] [--source N]"
message="$1"; shift
level="info"
source="${HERMES_AGENT:-unknown}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level)  level="${2:?--level needs a value}"; shift 2 ;;
    --source) source="${2:?--source needs a value}"; shift 2 ;;
    *) die "unknown arg '$1'" ;;
  esac
done
case "$level" in info|warn|alert|critical) ;; *) die "unknown level '$level'";; esac

# strip pipes/newlines so one notification stays one line
clean() { echo "${1//[|$'\n\r']/ }"; }

mkdir -p "$(dirname "$NOTIF_LOG")"
printf '%s|%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$(clean "$source")" "$(clean "$message")" >> "$NOTIF_LOG"

bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid):0" \
  --event notify --agent "$source" --detail "[$level] $(echo "$message" | head -c 100)" 2>/dev/null || true
