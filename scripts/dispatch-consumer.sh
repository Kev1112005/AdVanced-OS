#!/usr/bin/env bash
# dispatch-consumer.sh — pick up queued dispatches from ~/.hermes/requests/ and send to tmux.
# Serial channel: one send per agent per poll, skipped while the agent is thinking so we
# don't corrupt its context. Run from cron/watchdog. No jq — python3 for JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="${HERMES_REQUESTS_DIR:-$HOME/.hermes/requests}"
RETRY_DIR="$REQ_DIR/.retries"
NOTIF_LOG="${HERMES_NOTIF_LOG:-$HOME/.hermes/notifications.log}"
PAUSE_DIR="${HERMES_PAUSED_AGENTS_DIR:-$HOME/.hermes/paused-agents}"

# priority rank for the sort (lower = drained first); backoff seconds by failure count.
prio_rank() { case "$1" in critical) echo 0;; high) echo 1;; low) echo 3;; *) echo 2;; esac; }
retry_backoff() { case "$1" in 1) echo 30;; 2) echo 60;; 3) echo 120;; *) echo 0;; esac; }

# Serial channel: only one consumer drains the queue at a time. A concurrent run
# (manual + watchdog) would re-inject the same task. Non-blocking, so a second
# run just exits.
exec 9>"$HOME/.hermes/dispatch-consumer.lock"
flock -n 9 || exit 0

# ponytail: field extractor via python3 stdlib — one interpreter start per field is fine
# at queue volumes of a handful of files. Batch-parse if the queue ever gets deep.
field() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$1" "$2"; }

# --- alerting (Feature Gap 1.1) ---
ALERT_STATE_DIR="${HERMES_ALERT_STATE:-$HOME/.hermes/alerts}"
CB_CONFIG="$SCRIPT_DIR/../config/circuit-breaker.yaml"
DISPATCH_FAIL_THRESHOLD="$(grep -E '^[[:space:]]*cron_failure_threshold:' "$CB_CONFIG" 2>/dev/null | head -n1 | sed -E 's/.*:[[:space:]]*//; s/[[:space:]]*#.*$//')"
DISPATCH_FAIL_THRESHOLD="${DISPATCH_FAIL_THRESHOLD:-3}"
alert() { bash "$SCRIPT_DIR/hermes-alert.sh" send --level "$1" --title "$2" --message "$3" >/dev/null 2>&1 || true; }
# Count consecutive dispatch failures per agent; alert once the threshold is hit, then reset.
record_dispatch_failure() {
  local agent="$1" f n
  mkdir -p "$ALERT_STATE_DIR"
  f="$ALERT_STATE_DIR/dispatch-fail-$agent"
  n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 ))
  echo "$n" > "$f"
  if (( n >= DISPATCH_FAIL_THRESHOLD )); then
    alert alert "Dispatch failing: $agent" "$n consecutive dispatch failures for $agent — retries exhausted or session stuck. Manual check needed."
    echo 0 > "$f"   # re-alert only after another N failures
  fi
}
reset_dispatch_failure() { rm -f "$ALERT_STATE_DIR/dispatch-fail-$1" 2>/dev/null || true; }

# Ezekiel runs as `hermes -p ezekiel`, not a persistent tmux session. Launch it on
# demand in tmux so dispatches land and its output shows on the dashboard.
# Returns 0 once the TUI is ready for input, 1 if it never gets there.
# ponytail: readiness = the "Welcome to Hermes" banner, which prints only when the
# TUI is accepting input (unambiguous, unlike the ❯ glyph which also appears in
# load-time menus). --yolo skips approval prompts, so no dialog to navigate. 60s
# budget = observed deepseek-v4-flash cold start (~30-40s loading skills+MCP); a
# poll retries if a launch overruns. Tune the banner/timeout if the TUI changes.
wake_ezekiel() {
  tmux has-session -t ezekiel 2>/dev/null && return 0
  tmux new-session -d -s ezekiel -x 140 -y 40 2>/dev/null || return 1
  tmux send-keys -t ezekiel 'hermes -p ezekiel --yolo' Enter
  local waited=0
  while [ $waited -lt 60 ]; do
    sleep 3; waited=$((waited + 3))
    if tmux capture-pane -t ezekiel -p -S -40 2>/dev/null | grep -qiF 'Welcome to Hermes'; then
      sleep 2   # let the input box settle before the caller sends the task
      return 0
    fi
  done
  return 1
}

# Circuit breaker: if tripped, drain nothing this poll. Alert only on the set/clear
# edge (state file), so a 60s cron poll can't spam Kevin while the flag stays on.
STOP_STATE="$ALERT_STATE_DIR/global-stop.state"
if bash "$SCRIPT_DIR/global-stop.sh" check >/dev/null 2>&1; then
  if [[ ! -f "$STOP_STATE" ]]; then
    mkdir -p "$ALERT_STATE_DIR"; touch "$STOP_STATE"
    alert critical "Global stop engaged" "Circuit breaker tripped — dispatch queue paused until the stop flag clears."
  fi
  # Only output on circuit-breaker events — otherwise the no-agent cron stays silent
  echo "circuit breaker tripped — dispatch queue paused"
  exit 0
elif [[ -f "$STOP_STATE" ]]; then
  rm -f "$STOP_STATE"
  alert warn "Global stop cleared" "Dispatch queue resumed."
fi

shopt -s nullglob
files=("$REQ_DIR"/*.json)

# Process the queue only when non-empty, but always fall through to pipeline-advance
# below — agents finish their stage while the queue is empty.
if (( ${#files[@]} )); then

# Priority sort: critical > high > normal > low. Prefix each file with its rank,
# sort numerically, strip the rank back off. Filenames are UUIDs (no spaces).
mapfile -t files < <(
  for f in "${files[@]}"; do echo "$(prio_rank "$(field "$f" priority)") $f"; done \
    | sort -n -k1,1 | cut -d' ' -f2-
)

for req_file in "${files[@]}"; do
  if ! agent="$(field "$req_file" agent)" || [[ -z "$agent" ]]; then
    rm -f "$req_file"
    continue
  fi
  task="$(field "$req_file" task)"
  cid="$(field "$req_file" correlation_id)"
  type="$(field "$req_file" type)"
  pipeline_id="$(field "$req_file" pipeline_id)"
  agent_id="$(field "$req_file" agent_id)"

  # A paused agent keeps its queued orders durable but receives no new input.
  # Mission Control writes the pause flag; resume removes it.
  if [[ -f "$PAUSE_DIR/${agent_id:-$agent}" ]]; then
    continue
  fi

  # Type-aware routing: notify/research surface to Kevin, not a worker session.
  # Append to the notifications log; notification-tail.sh (end of run) delivers it.
  if [[ "$type" == notify || "$type" == research ]]; then
    mkdir -p "$(dirname "$NOTIF_LOG")"
    printf '%s|%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" info "$agent" "${task//[|$'\n\r']/ }" >> "$NOTIF_LOG"
    bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" --event "$type" --agent "$agent" --detail "$(echo "$task" | head -c 100)" 2>/dev/null || true
    rm -f "$req_file"
    continue
  fi

  # Ezekiel isn't a persistent session — wake it on demand. Other agents must
  # already be a live tmux session; unknown/dead agent → leave for a later poll.
  if [[ "$agent" == ezekiel ]]; then
    if ! wake_ezekiel; then
      bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" --event fail --agent ezekiel --detail "wake failed / not ready within 60s"
      record_dispatch_failure ezekiel
      continue
    fi
  elif ! tmux has-session -t "$agent" 2>/dev/null; then
    continue
  fi

  # Don't inject while the agent is mid-thought. Retry with backoff (30s/60s/120s)
  # so a busy agent doesn't hold up its request forever; give up after the 4th failure.
  if tmux capture-pane -t "$agent" -p -S -3 2>/dev/null | grep -qE 'Spinning|Baking|Hatching|Misting|Thinking|Deliberating|Tomfoolering'; then
    rid="$(basename "$req_file" .json)"
    mkdir -p "$RETRY_DIR"
    count=0; last=0
    [[ -f "$RETRY_DIR/$rid" ]] && read -r count last < "$RETRY_DIR/$rid"
    now="$(date +%s)"
    # still inside the backoff window for the current count — don't count this probe
    (( now - last < $(retry_backoff "$count") )) && continue
    count=$((count + 1))
    if (( count >= 4 )); then
      bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" --event circuit_break --agent "$agent" --detail "dispatch abandoned: agent busy through 4 retries"
      record_dispatch_failure "$agent"
      rm -f "$req_file" "$RETRY_DIR/$rid"
      continue
    fi
    echo "$count $now" > "$RETRY_DIR/$rid"
    continue
  fi

  # Send the task. Large tasks (≥2K chars, typical for pipeline dispatches with
  # accumulated context) can overflow tmux send-keys' buffer. Write to a temp file
  # and send a short reference command instead — the established Belial pattern.
  task_len="${#task}"
  if (( task_len >= 2000 )); then
    task_file="/tmp/dispatch-${agent}-$(basename "$req_file" .json).md"
    printf '%s' "$task" > "$task_file"
    ref_cmd="Implement the task in $task_file. Read it first, build it. Go."
    if ! tmux send-keys -t "$agent" "$ref_cmd" Enter 2>/dev/null; then
      bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" --event fail --agent "$agent" --detail "dispatch send (file ref) failed"
      record_dispatch_failure "$agent"
      continue
    fi
  else
    if ! tmux send-keys -t "$agent" "$task" Enter 2>/dev/null; then
      bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" --event fail --agent "$agent" --detail "dispatch send failed"
      record_dispatch_failure "$agent"
      continue
    fi
  fi
  sleep 5
  tmux send-keys -t "$agent" Enter 2>/dev/null || true

  bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" --event dispatch --agent "$agent" --detail "$(echo "$task" | head -c 100)"
  reset_dispatch_failure "$agent"

  # Record pipeline delivery so pipeline-advance knows the stage was actually sent.
  # state (researching/scaffolding/building) maps to the stage dir (research/scaffold/build).
  if [[ "$type" == pipeline && -n "${pipeline_id:-}" ]]; then
    pd_dir="$HOME/.hermes/dev-pipeline/$pipeline_id"
    if [[ -d "$pd_dir" ]]; then
      case "$(cat "$pd_dir/state" 2>/dev/null)" in
        researching) sub=research ;; scaffolding) sub=scaffold ;; building) sub=build ;; *) sub="" ;;
      esac
      if [[ -n "$sub" ]]; then
        mkdir -p "$pd_dir/$sub"
        echo "$agent" > "$pd_dir/$sub/agent"
        echo "$cid"   > "$pd_dir/$sub/dispatch_cid"
        date -u +%Y-%m-%dT%H:%M:%SZ > "$pd_dir/$sub/sent_at"
      fi
    fi
  fi

  rm -f "$req_file" "$RETRY_DIR/$(basename "$req_file" .json)"
done

# Surface any undelivered notifications to Kevin (no_agent cron captures this stdout).
bash "$SCRIPT_DIR/notification-tail.sh" 2>/dev/null || true

bash "$SCRIPT_DIR/status-snapshot.sh" >/dev/null 2>&1 || true

fi  # end non-empty-queue processing

# Advance dev pipelines every poll: detect finished stages, capture output, dispatch next.
# ponytail: runs under the same flock, so the 5s output-flush sleep can hold the lock
# briefly per advancing pipeline — fine at handful-of-pipelines volume.
bash "$SCRIPT_DIR/pipeline-advance.sh" >/dev/null 2>&1 || true
