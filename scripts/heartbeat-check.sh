#!/usr/bin/env bash
# heartbeat-check.sh — active liveness probe for persistent agent tmux sessions.
# Distinguishes active / idle / stuck / offline. "stuck" = session alive, sitting
# at the prompt, and output unchanged for >N minutes (looks wedged).
#
# Usage:
#   heartbeat-check.sh check                 # JSON {"claude-belial":"idle",...} for all persistent sessions
#   heartbeat-check.sh status <session>      # single word for one session (used by status-snapshot.sh)
#
# State per session: $HOME/.hermes/alerts/heartbeat/<session>/{last_output_hash,idle_since}
set -euo pipefail

STATE_DIR="${HERMES_HEARTBEAT_DIR:-$HOME/.hermes/alerts/heartbeat}"
STUCK_MINUTES="${HERMES_STUCK_MINUTES:-5}"
PERSISTENT=(claude-belial claude-obsoletebot claude-remote-control)

# One word for one session. active | idle | stuck | offline
session_status() {
  local name="$1" cap hash sdir hashfile idlefile prev idle_since now age
  command -v tmux >/dev/null 2>&1 || { echo offline; return; }
  cap="$(tmux capture-pane -t "$name" -p -S -6 2>/dev/null)" || { echo offline; return; }

  if grep -qE 'Spinning|Baking|Hatching|Misting|Thinking|Deliberating' <<<"$cap"; then
    echo active; return
  fi
  # Not at a known prompt and not thinking -> treat as idle (nothing to wedge on).
  grep -qE '❯|⏵⏵' <<<"$cap" || { echo idle; return; }

  sdir="$STATE_DIR/$name"; mkdir -p "$sdir"
  hashfile="$sdir/last_output_hash"; idlefile="$sdir/idle_since"
  hash="$(cksum <<<"$cap" | cut -d' ' -f1)"
  prev="$(cat "$hashfile" 2>/dev/null || echo)"
  now="$(date +%s)"

  if [[ "$hash" != "$prev" ]]; then
    # Output changed since last probe -> fresh, restart the idle clock.
    echo "$hash" > "$hashfile"; echo "$now" > "$idlefile"; echo idle; return
  fi
  idle_since="$(cat "$idlefile" 2>/dev/null || echo "$now")"
  age=$(( (now - idle_since) / 60 ))
  if (( age >= STUCK_MINUTES )); then echo stuck; else echo idle; fi
}

case "${1:-check}" in
  status)
    session_status "${2:?session name required}" ;;
  check)
    out="{" first=1
    for s in "${PERSISTENT[@]}"; do
      [[ $first -eq 1 ]] && first=0 || out+=","
      out+="\"$s\":\"$(session_status "$s")\""
    done
    echo "$out}" ;;
  *) echo "usage: heartbeat-check.sh check|status <session>" >&2; exit 1 ;;
esac
