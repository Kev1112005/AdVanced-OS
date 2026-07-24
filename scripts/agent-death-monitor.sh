#!/usr/bin/env bash
# agent-death-monitor.sh — alert when a persistent agent's tmux session vanishes.
# Cron this every ~5m. On-demand agents (e.g. ezekiel) are NOT monitored — their
# exit is normal. Suppressed while the global stop flag is set (deaths are then
# intentional). Per-agent cooldown prevents flooding on a flapping session.
#
# Usage: agent-death-monitor.sh [config-path]
# Exit codes: 0 always (best-effort monitor; never blocks a cron)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/../config/circuit-breaker.yaml}"
STATE_DIR="${HERMES_ALERT_STATE:-$HOME/.hermes/alerts}/agent-liveness"
STOP_FILE="${HERMES_STOP_FILE:-$HOME/.hermes/stop}"

# Persistent sessions that should stay alive. On-demand profiles are excluded on
# purpose (they die between dispatches). Keep in sync with status-snapshot.sh.
# Override with HERMES_MONITORED_AGENTS (space-separated) to reconfigure or test.
read -r -a MONITORED <<< "${HERMES_MONITORED_AGENTS:-claude-belial claude-obsoletebot claude-remote-control}"

# `|| true` so an absent key doesn't fail the pipeline under `set -o pipefail`
# (grep exits 1 on no match) — that would kill the script before the :-default applies.
yaml_get() {
  local key="${1:-}" file="${2:-}"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "error: invalid configuration key" >&2
    return 1
  }
  { grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null || true; } | head -n1 \
    | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^\"//; s/\"$//"
}
COOLDOWN="$(yaml_get agent_death_cooldown "$CONFIG")"; COOLDOWN="${COOLDOWN:-300}"

command -v tmux >/dev/null 2>&1 || exit 0
mkdir -p "$STATE_DIR"
stop_set=0; [[ -f "$STOP_FILE" ]] && stop_set=1
now="$(date +%s)"

for s in "${MONITORED[@]}"; do
  alive="$STATE_DIR/alive-$s"
  cool="$STATE_DIR/cooldown-$s"

  if tmux has-session -t "$s" 2>/dev/null; then
    touch "$alive"            # seen alive → arm the death detector
    continue
  fi

  # session is down
  [[ -f "$alive" ]] || continue          # never seen alive → nothing to mourn
  if (( stop_set )); then                # intentional stop → disarm, don't alert
    rm -f "$alive"
    continue
  fi
  if [[ -f "$cool" ]]; then              # within cooldown → wait (keep armed, retry later)
    last="$(cat "$cool" 2>/dev/null || echo 0)"
    if (( now - last < COOLDOWN )); then continue; fi
  fi

  bash "$SCRIPT_DIR/hermes-alert.sh" send --level alert \
    --title "Agent session died: $s" \
    --message "tmux session '$s' is gone and no global stop is set — it may have crashed. Investigate and restart if needed." \
    --config "$CONFIG" >/dev/null 2>&1 || true
  echo "$now" > "$cool"
  rm -f "$alive"                         # transition consumed; re-arms if it returns
  echo "agent-death-monitor: ALERTED — $s is down"
done

exit 0
