#!/usr/bin/env bash
# notification-tail.sh — Phase 1a: read/format ~/.hermes/notifications.log for Kevin.
# Log line format: timestamp|level|source|message
#
# Usage:
#   notification-tail.sh                 Deliver undelivered notifications, advance the marker
#   notification-tail.sh --peek          Show undelivered without advancing the marker
#   notification-tail.sh --all [-n N]    Show last N (default 20), ignore the marker
#
# "Delivered" is tracked as a line count in ~/.hermes/.notifications-delivered so the
# same notification isn't surfaced to Kevin on every poll.
set -euo pipefail

NOTIF_LOG="${HERMES_NOTIF_LOG:-$HOME/.hermes/notifications.log}"
MARKER="${HERMES_NOTIF_MARKER:-$HOME/.hermes/.notifications-delivered}"

mode="deliver"
limit=20
while [[ $# -gt 0 ]]; do
  case "$1" in
    --peek) mode="peek"; shift ;;
    --all)  mode="all"; shift ;;
    -n|--limit) limit="${2:?-n needs a value}"; shift 2 ;;
    *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
  esac
done

[[ -f "$NOTIF_LOG" ]] || exit 0

# nice one-line format: [LEVEL] source — message  (ts)
fmt() { awk -F'|' '{printf "[%s] %s — %s  (%s)\n", toupper($2), $3, $4, $1}'; }

total="$(wc -l < "$NOTIF_LOG")"

if [[ "$mode" == all ]]; then
  tail -n "$limit" "$NOTIF_LOG" | fmt
  exit 0
fi

delivered=0
[[ -f "$MARKER" ]] && delivered="$(cat "$MARKER" 2>/dev/null || echo 0)"
[[ "$delivered" =~ ^[0-9]+$ ]] || delivered=0
# log rotated/truncated -> reset
(( delivered > total )) && delivered=0

(( total > delivered )) || exit 0   # nothing new

tail -n +"$((delivered + 1))" "$NOTIF_LOG" | fmt

[[ "$mode" == peek ]] || echo "$total" > "$MARKER"
