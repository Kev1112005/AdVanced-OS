#!/usr/bin/env bash
# dispatch-consumer.sh — pick up queued dispatches from ~/.hermes/requests/ and send to tmux.
# Serial channel: one send per agent per poll, skipped while the agent is thinking so we
# don't corrupt its context. Run from cron/watchdog. No jq — python3 for JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="${HERMES_REQUESTS_DIR:-$HOME/.hermes/requests}"

# ponytail: field extractor via python3 stdlib — one interpreter start per field is fine
# at queue volumes of a handful of files. Batch-parse if the queue ever gets deep.
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

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

  # Target must be a live tmux session; unknown/dead agent → leave for a later poll.
  if ! tmux has-session -t "$agent" 2>/dev/null; then
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
