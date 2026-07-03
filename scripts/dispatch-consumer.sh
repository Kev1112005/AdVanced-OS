#!/usr/bin/env bash
# dispatch-consumer.sh — pick up queued dispatches from ~/.hermes/requests/ and send to tmux.
# Serial channel: one send per agent per poll, skipped while the agent is thinking so we
# don't corrupt its context. Run from cron/watchdog. No jq — python3 for JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="${HERMES_REQUESTS_DIR:-$HOME/.hermes/requests}"

# Serial channel: only one consumer drains the queue at a time. A concurrent run
# (manual + watchdog) would re-inject the same task — worse now that Ornith's wake
# holds a request in place for up to 30s. Non-blocking, so a second run just exits.
exec 9>"$HOME/.hermes/dispatch-consumer.lock"
flock -n 9 || exit 0

# ponytail: field extractor via python3 stdlib — one interpreter start per field is fine
# at queue volumes of a handful of files. Batch-parse if the queue ever gets deep.
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

# Ornith runs as `hermes -p ornith`, not a persistent tmux session. Launch it on
# demand in tmux so dispatches land and its output shows on the dashboard.
# Returns 0 when a ready prompt appears within 30s, 1 otherwise.
# ponytail: readiness globs (⏵⏵/❯) and the trust-dialog text are UI heuristics —
# tune them here if the Hermes prompt changes; timing is the only real knob.
wake_ornith() {
  tmux has-session -t ornith 2>/dev/null && return 0
  tmux new-session -d -s ornith -x 140 -y 40 2>/dev/null || return 1
  tmux send-keys -t ornith 'hermes -p ornith' Enter
  local i pane
  for i in $(seq 1 10); do          # up to 30s: 10 × 3s
    sleep 3
    pane="$(tmux capture-pane -t ornith -p -S -20 2>/dev/null || true)"
    if grep -qE 'Do you trust|permission|proceed' <<<"$pane"; then
      # First-launch trust/permissions dialog: Enter, Down, Enter.
      tmux send-keys -t ornith Enter; sleep 1
      tmux send-keys -t ornith Down;  sleep 1
      tmux send-keys -t ornith Enter
      continue
    fi
    grep -qE '⏵⏵|❯' <<<"$pane" && return 0
  done
  return 1
}

# Circuit breaker: if tripped, drain nothing this poll.
if bash "$SCRIPT_DIR/global-stop.sh" check >/dev/null 2>&1; then
  # Only output on circuit-breaker events — otherwise the no-agent cron stays silent
  echo "circuit breaker tripped — dispatch queue paused"
  exit 0
fi

shopt -s nullglob
files=("$REQ_DIR"/*.json)
[[ ${#files[@]} -eq 0 ]] && exit 0  # silent on empty queue

for req_file in "${files[@]}"; do
  if ! agent="$(field "$req_file" agent)" || [[ -z "$agent" ]]; then
    rm -f "$req_file"
    continue
  fi
  task="$(field "$req_file" task)"
  cid="$(field "$req_file" correlation_id)"

  # Ornith isn't a persistent session — wake it on demand. Other agents must
  # already be a live tmux session; unknown/dead agent → leave for a later poll.
  if [[ "$agent" == ornith ]]; then
    if ! wake_ornith; then
      bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" --event fail --agent ornith --detail "wake failed / perms not resolved within 30s"
      continue
    fi
  elif ! tmux has-session -t "$agent" 2>/dev/null; then
    continue
  fi

  # Don't inject while the agent is mid-thought — leave for next poll.
  if tmux capture-pane -t "$agent" -p -S -3 2>/dev/null | grep -qE 'Spinning|Baking|Hatching|Misting|Thinking|Deliberating'; then
    continue
  fi

  # Send the task. Second Enter is the ponytail submit quirk — first Enter only inserts.
  if ! tmux send-keys -t "$agent" "$task" Enter 2>/dev/null; then
    bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" --event fail --agent "$agent" --detail "dispatch send failed"
    continue
  fi
  sleep 5
  tmux send-keys -t "$agent" Enter 2>/dev/null || true

  bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" --event dispatch --agent "$agent" --detail "$(echo "$task" | head -c 100)"
  rm -f "$req_file"
done

bash "$SCRIPT_DIR/status-snapshot.sh" >/dev/null 2>&1 || true
