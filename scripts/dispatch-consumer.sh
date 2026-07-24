#!/usr/bin/env bash
# dispatch-consumer.sh — drain durable requests through one global tmux lane.
#
# Worker delivery is fail-closed: one persistent lane record, a full breaker
# check immediately before send, immutable QA registration before any input,
# and no automatic retry after an ambiguous transport attempt.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="${HERMES_REQUESTS_DIR:-$HOME/.hermes/requests}"
RETRY_DIR="$REQ_DIR/.retries"
INVALID_DIR="$REQ_DIR/.invalid"
UNCERTAIN_DIR="$REQ_DIR/.uncertain"
NOTIF_LOG="${HERMES_NOTIF_LOG:-$HOME/.hermes/notifications.log}"
PAUSE_DIR="${HERMES_PAUSED_AGENTS_DIR:-$HOME/.hermes/paused-agents}"
PIPE_DIR="${HERMES_PIPELINE_DIR:-$HOME/.hermes/dev-pipeline}"
LANE_FILE="${HERMES_DISPATCH_LANE_FILE:-$HOME/.hermes/dispatch-lane.json}"
CONSUMER_LOCK="${HERMES_DISPATCH_LOCK:-${HERMES_DISPATCH_CONSUMER_LOCK:-$HOME/.hermes/dispatch-consumer.lock}}"
CB_CONFIG="${HERMES_CIRCUIT_BREAKER_CONFIG:-$SCRIPT_DIR/../config/circuit-breaker.yaml}"
SUBMIT_DELAY="${HERMES_DISPATCH_SUBMIT_DELAY:-5}"
TRANSPORT_TIMEOUT="${HERMES_DISPATCH_TRANSPORT_TIMEOUT:-5}"
TASK_FILE_DIR="${HERMES_DISPATCH_TASK_DIR:-$HOME/.hermes/dispatch-tasks}"

[[ "$SUBMIT_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || SUBMIT_DELAY=5
[[ "$TRANSPORT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || TRANSPORT_TIMEOUT=5

prio_rank() {
  case "$1" in
    critical) echo 0 ;;
    high) echo 1 ;;
    low) echo 3 ;;
    *) echo 2 ;;
  esac
}

mkdir -p "$REQ_DIR" "$(dirname "$CONSUMER_LOCK")"
exec 9>"$CONSUMER_LOCK"
flock -n 9 || exit 0

# --- alerting ---
ALERT_STATE_DIR="${HERMES_ALERT_STATE:-$HOME/.hermes/alerts}"
DISPATCH_FAIL_THRESHOLD="$(
  grep -E '^[[:space:]]*cron_failure_threshold:' "$CB_CONFIG" 2>/dev/null \
    | head -n1 | sed -E 's/.*:[[:space:]]*//; s/[[:space:]]*#.*$//' || true
)"
DISPATCH_FAIL_THRESHOLD="${DISPATCH_FAIL_THRESHOLD:-3}"
alert() {
  bash "$SCRIPT_DIR/hermes-alert.sh" send --level "$1" --title "$2" --message "$3" \
    --config "$CB_CONFIG" >/dev/null 2>&1 || true
}
record_dispatch_failure() {
  local agent="$1" file count
  mkdir -p "$ALERT_STATE_DIR"
  file="$ALERT_STATE_DIR/dispatch-fail-$agent"
  count=$(( $(cat "$file" 2>/dev/null || echo 0) + 1 ))
  echo "$count" > "$file"
  if (( count >= DISPATCH_FAIL_THRESHOLD )); then
    alert alert "Dispatch failing: $agent" \
      "$count consecutive dispatch failures for $agent. Manual inspection is required."
    echo 0 > "$file"
  fi
}
reset_dispatch_failure() {
  rm -f "$ALERT_STATE_DIR/dispatch-fail-$1" 2>/dev/null || true
}
log_event() {
  bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$1" --event "$2" \
    --agent "$3" --detail "$4" 2>/dev/null || true
}
notify_line() {
  mkdir -p "$(dirname "$NOTIF_LOG")"
  printf '%s|%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" \
    "${3//[|$'\n\r']/ }" >> "$NOTIF_LOG"
}

atomic_line() {
  local path="$1" value="$2" temporary
  mkdir -p "$(dirname "$path")"
  temporary="$(mktemp "${path}.tmp.XXXXXX")"
  printf '%s\n' "$value" > "$temporary"
  mv -f "$temporary" "$path"
}

# Ezekiel is on-demand. Starting the profile is not task delivery; the lane is
# acquired only after its prompt is ready.
wake_ezekiel() {
  tmux has-session -t ezekiel 2>/dev/null && return 0
  tmux new-session -d -s ezekiel -x 140 -y 40 2>/dev/null || return 1
  tmux send-keys -t ezekiel 'hermes -p ezekiel --yolo' Enter
  local waited=0
  while (( waited < 60 )); do
    sleep 3
    waited=$((waited + 3))
    if tmux capture-pane -t ezekiel -p -S -40 2>/dev/null \
      | grep -qiF 'Welcome to Hermes'; then
      sleep 2
      return 0
    fi
  done
  return 1
}

# Parse and validate one request exactly once. Values are NUL-delimited so
# multiline task text never becomes executable shell syntax.
parse_request() {
  local request_file="$1"
  local -a values=()
  mapfile -d '' -t values < <(python3 - "$request_file" <<'PY'
import json
import pathlib
import re
import sys


def emit(*values):
    data = b"\0".join(str(value).encode("utf-8") for value in values) + b"\0"
    sys.stdout.buffer.write(data)


path = pathlib.Path(sys.argv[1])
try:
    request = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(request, dict):
        raise ValueError("root must be an object")
    request_id = str(request.get("request_id") or "")
    correlation_id = str(request.get("correlation_id") or "")
    agent = str(request.get("agent") or "")
    agent_id = str(request.get("agent_id") or "")
    task = str(request.get("task") or "")
    request_type = str(request.get("type") or "order")
    pipeline_id = str(request.get("pipeline_id") or "")
    priority = str(request.get("priority") or "normal")
    qa_required = request.get("qa_required") is True
    if not re.fullmatch(r"[A-Za-z0-9._:-]+", request_id):
        raise ValueError("invalid request_id")
    if not re.fullmatch(r"[^:]+:[0-9]+", correlation_id):
        raise ValueError("invalid correlation_id")
    if not re.fullmatch(r"[A-Za-z0-9._:-]+", agent):
        raise ValueError("invalid agent")
    if agent_id and not re.fullmatch(r"[A-Za-z0-9._:-]+", agent_id):
        raise ValueError("invalid agent_id")
    if request_type not in {
        "order", "task", "ticket", "pipeline", "qa", "notify", "research", "log"
    }:
        raise ValueError("invalid type")
    if pipeline_id and not re.fullmatch(r"[A-Za-z0-9._:-]+", pipeline_id):
        raise ValueError("invalid pipeline_id")
    if priority not in {"low", "normal", "high", "critical"}:
        raise ValueError("invalid priority")
    if not task or "\0" in task:
        raise ValueError("task is empty or contains NUL")
except (OSError, ValueError, TypeError) as exc:
    emit("ERROR", str(exc))
else:
    emit(
        "OK",
        request_id,
        correlation_id,
        agent,
        agent_id,
        task,
        request_type,
        pipeline_id,
        "true" if qa_required else "false",
        priority,
    )
PY
)
  if [[ "${values[0]:-ERROR}" != "OK" || ${#values[@]} -ne 10 ]]; then
    PARSED_ERROR="${values[1]:-request parser failed}"
    return 1
  fi
  PARSED_REQUEST_ID="${values[1]}"
  PARSED_CID="${values[2]}"
  PARSED_AGENT="${values[3]}"
  PARSED_AGENT_ID="${values[4]}"
  PARSED_TASK="${values[5]}"
  PARSED_TYPE="${values[6]}"
  PARSED_PIPELINE_ID="${values[7]}"
  PARSED_QA_REQUIRED="${values[8]}"
  PARSED_PRIORITY="${values[9]}"
}

quarantine_invalid() {
  local request_file="$1" detail="$2" destination
  mkdir -p "$INVALID_DIR"
  destination="$INVALID_DIR/$(basename "$request_file").$(date +%s).$$"
  mv -f "$request_file" "$destination"
  log_event "invalid:0" fail dispatch-consumer \
    "quarantined $(basename "$request_file"): ${detail:0:200}"
  notify_line warn dispatch-consumer \
    "Invalid request quarantined: $(basename "$request_file") — ${detail:0:160}"
}

mark_pipeline_delivery() {
  local pipeline_id="$1" request_id="$2" agent="$3" cid="$4"
  local pipeline_dir="$PIPE_DIR/$pipeline_id" stage
  [[ -d "$pipeline_dir" ]] || return 1
  case "$(cat "$pipeline_dir/state" 2>/dev/null)" in
    researching) stage=research ;;
    scaffolding) stage=scaffold ;;
    building) stage=build ;;
    *) return 1 ;;
  esac
  atomic_line "$pipeline_dir/$stage/agent" "$agent"
  atomic_line "$pipeline_dir/$stage/dispatch_cid" "$cid"
  atomic_line "$pipeline_dir/$stage/request_id" "$request_id"
  atomic_line "$pipeline_dir/$stage/sent_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

mark_pipeline_uncertain() {
  local pipeline_id="$1" request_id="$2"
  local pipeline_dir="$PIPE_DIR/$pipeline_id" stage
  [[ -d "$pipeline_dir" ]] || return 0
  case "$(cat "$pipeline_dir/state" 2>/dev/null)" in
    researching) stage=research ;;
    scaffolding) stage=scaffold ;;
    building) stage=build ;;
    *) return 0 ;;
  esac
  atomic_line "$pipeline_dir/$stage/request_id" "$request_id"
  atomic_line "$pipeline_dir/$stage/dispatch_uncertain_at" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

mark_uncertain() {
  local request_file="$1" request_id="$2" cid="$3" agent="$4" detail="$5"
  local requires_qa="$6" request_type="$7" pipeline_id="$8" destination
  bash "$SCRIPT_DIR/dispatch-lane.sh" transition --request-id "$request_id" \
    --status uncertain >/dev/null 2>&1 || true
  if [[ "$requires_qa" == true ]]; then
    bash "$SCRIPT_DIR/qa-gate.sh" transition --request-id "$request_id" \
      --status dispatch_uncertain >/dev/null 2>&1 || true
  elif [[ "$request_type" == pipeline ]]; then
    mark_pipeline_uncertain "$pipeline_id" "$request_id"
  fi
  mkdir -p "$UNCERTAIN_DIR"
  destination="$UNCERTAIN_DIR/$(basename "$request_file")"
  if [[ -e "$destination" ]]; then
    destination="$destination.$(date +%s).$$"
  fi
  mv -f "$request_file" "$destination" 2>/dev/null || true
  log_event "$cid" fail "$agent" "dispatch uncertain: ${detail:0:180}"
  notify_line alert dispatch-consumer \
    "Dispatch uncertain for $request_id on $agent; lane remains closed for inspection."
  record_dispatch_failure "$agent"
}

# Global stop prevents intake and new worker sends, but current work may finish
# cooperatively and its QA/pipeline completion still needs to be recorded.
GLOBAL_STOPPED=0
STOP_STATE="$ALERT_STATE_DIR/global-stop.state"
if bash "$SCRIPT_DIR/global-stop.sh" check >/dev/null 2>&1; then
  GLOBAL_STOPPED=1
  if [[ ! -f "$STOP_STATE" ]]; then
    mkdir -p "$ALERT_STATE_DIR"
    touch "$STOP_STATE"
    alert critical "Global stop engaged" \
      "Circuit breaker tripped — new dispatches are paused until explicit clear."
  fi
elif [[ -f "$STOP_STATE" ]]; then
  rm -f "$STOP_STATE"
  alert warn "Global stop cleared" "Dispatch queue resumed."
fi

if (( ! GLOBAL_STOPPED )); then
  bash "$SCRIPT_DIR/ticket-scan.sh" scan >/dev/null 2>&1 || true
fi

shopt -s nullglob
discovered=("$REQ_DIR"/*.json)
declare -a request_files=()
declare -a request_ids=()
declare -a cids=()
declare -a agents=()
declare -a agent_ids=()
declare -a tasks=()
declare -a types=()
declare -a pipeline_ids=()
declare -a qa_requireds=()
declare -a priorities=()

for request_file in "${discovered[@]}"; do
  if ! parse_request "$request_file"; then
    quarantine_invalid "$request_file" "$PARSED_ERROR"
    continue
  fi
  index="${#request_files[@]}"
  request_files[index]="$request_file"
  request_ids[index]="$PARSED_REQUEST_ID"
  cids[index]="$PARSED_CID"
  agents[index]="$PARSED_AGENT"
  agent_ids[index]="$PARSED_AGENT_ID"
  tasks[index]="$PARSED_TASK"
  types[index]="$PARSED_TYPE"
  pipeline_ids[index]="$PARSED_PIPELINE_ID"
  qa_requireds[index]="$PARSED_QA_REQUIRED"
  priorities[index]="$PARSED_PRIORITY"
done

ordered=()
if (( ${#discovered[@]} )); then
  mapfile -t ordered < <(
    for index in "${!request_files[@]}"; do
      printf '%s %s\n' "$(prio_rank "${priorities[index]}")" "$index"
    done | sort -n -k1,1 | cut -d' ' -f2
  )
fi

for index in "${ordered[@]}"; do
  request_file="${request_files[index]}"
  [[ -f "$request_file" ]] || continue
  request_id="${request_ids[index]}"
  cid="${cids[index]}"
  agent="${agents[index]}"
  agent_id="${agent_ids[index]}"
  task="${tasks[index]}"
  request_type="${types[index]}"
  pipeline_id="${pipeline_ids[index]}"
  qa_required="${qa_requireds[index]}"

  # Completion/control-plane records do not acquire the worker lane.
  if [[ "$request_type" == qa ]]; then
    qa_id="$task"
    if ! [[ "$qa_id" =~ ^[A-Za-z0-9._:-]+$ ]]; then
      quarantine_invalid "$request_file" "qa task is not a valid request id"
      continue
    fi
    set +e
    qa_output="$(bash "$SCRIPT_DIR/qa-gate.sh" run \
      --request-id "$qa_id" --completion-file "$request_file" 2>&1)"
    qa_code=$?
    set -e
    if (( qa_code == 0 || qa_code == 1 )); then
      if (( qa_code == 0 )); then
        log_event "$cid" qa_pass "$agent" "QA passed for $qa_id"
        notify_line info qa-gate "QA passed for $qa_id"
      else
        log_event "$cid" qa_fail "$agent" "QA failed for $qa_id"
        notify_line warn qa-gate "QA failed for $qa_id; review Mission Control"
      fi
      bash "$SCRIPT_DIR/dispatch-lane.sh" release --request-id "$qa_id" \
        --reason qa_terminal >/dev/null 2>&1 || true
      rm -f "$REQ_DIR/$qa_id.json" "$UNCERTAIN_DIR/$qa_id.json"
      rm -f "$request_file" "$RETRY_DIR/qa-$request_id"
    else
      marker="$RETRY_DIR/qa-$request_id"
      if [[ ! -f "$marker" ]]; then
        mkdir -p "$RETRY_DIR"
        touch "$marker"
        log_event "$cid" qa_fail "$agent" \
          "QA operational error for $qa_id: $(echo "$qa_output" | tail -c 160)"
        notify_line warn qa-gate \
          "QA could not run for $qa_id; completion remains queued for retry."
      fi
    fi
    continue
  fi

  if [[ "$request_type" == notify || "$request_type" == research \
    || "$request_type" == log ]]; then
    notify_line info "$agent" "$task"
    log_event "$cid" "$request_type" "$agent" "$(echo "$task" | head -c 100)"
    rm -f "$request_file"
    continue
  fi

  # A worker request without a terminal completion contract cannot safely own
  # the persistent lane. Hold it visibly until the contract is defined.
  requires_qa=false
  if [[ "$qa_required" == true || "$request_type" == ticket ]]; then
    requires_qa=true
  elif [[ "$request_type" != pipeline ]]; then
    marker="$RETRY_DIR/unsupported-$request_id"
    if [[ ! -f "$marker" ]]; then
      mkdir -p "$RETRY_DIR"
      touch "$marker"
      log_event "$cid" fail "$agent" \
        "unsupported completion contract; request held without dispatch"
      notify_line warn dispatch-consumer \
        "Request $request_id is held: worker tasks require QA or pipeline completion."
    fi
    continue
  fi

  (( GLOBAL_STOPPED )) && continue
  [[ -f "$PAUSE_DIR/${agent_id:-$agent}" ]] && continue

  # An occupied or corrupt lane is fail-closed. Completion records elsewhere in
  # this same poll may release it before a later worker request is considered.
  if [[ -e "$LANE_FILE" ]]; then
    continue
  fi

  set +e
  breaker_output="$(bash "$SCRIPT_DIR/circuit-breaker.sh" check \
    --correlation-id "$cid" --config "$CB_CONFIG" 2>&1)"
  breaker_code=$?
  set -e
  if (( breaker_code != 0 )); then
    marker="$RETRY_DIR/breaker-$request_id-$breaker_code"
    if [[ ! -f "$marker" ]]; then
      mkdir -p "$RETRY_DIR"
      touch "$marker"
      log_event "$cid" circuit_break "$agent" \
        "delivery blocked by circuit breaker ($breaker_code): $(echo "$breaker_output" | tail -c 140)"
    fi
    continue
  fi
  rm -f "$RETRY_DIR"/breaker-"$request_id"-* 2>/dev/null || true

  if [[ "$agent" == ezekiel ]]; then
    if ! wake_ezekiel; then
      log_event "$cid" fail ezekiel "wake failed / not ready within 60s"
      record_dispatch_failure ezekiel
      continue
    fi
  elif ! tmux has-session -t "$agent" 2>/dev/null; then
    continue
  fi

  # Thinking is normal backpressure. Never count probes toward deletion.
  if tmux capture-pane -t "$agent" -p -S -3 2>/dev/null \
    | grep -qE 'Spinning|Baking|Hatching|Misting|Thinking|Deliberating|Tomfoolering'; then
    continue
  fi

  if ! bash "$SCRIPT_DIR/dispatch-lane.sh" acquire \
    --request-file "$request_file" >/dev/null 2>&1; then
    continue
  fi

  if [[ "$requires_qa" == true ]]; then
    if ! qa_registration="$(bash "$SCRIPT_DIR/qa-gate.sh" register \
      --request-file "$request_file" 2>&1)"; then
      log_event "$cid" qa_fail "$agent" \
        "QA registration failed for $request_id: $(echo "$qa_registration" | tail -c 160)"
      bash "$SCRIPT_DIR/dispatch-lane.sh" release --request-id "$request_id" \
        --reason preflight_failed >/dev/null 2>&1 || true
      continue
    fi
  fi

  send_text="$task"
  if (( ${#task} >= 2000 )); then
    mkdir -p "$TASK_FILE_DIR"
    chmod 700 "$TASK_FILE_DIR"
    task_file="$TASK_FILE_DIR/dispatch-${agent}-${request_id}.md"
    temporary="$(mktemp "${task_file}.tmp.XXXXXX")"
    if ! printf '%s' "$task" > "$temporary" || ! mv -f "$temporary" "$task_file"; then
      rm -f "$temporary"
      bash "$SCRIPT_DIR/dispatch-lane.sh" release --request-id "$request_id" \
        --reason preflight_failed >/dev/null 2>&1 || true
      log_event "$cid" fail "$agent" "could not persist large dispatch task file"
      continue
    fi
    chmod 600 "$task_file"
    send_text="Implement the task in $task_file. Read it first, build it. Go."
  fi

  if ! bash "$SCRIPT_DIR/dispatch-lane.sh" transition --request-id "$request_id" \
    --status submitting >/dev/null 2>&1; then
    bash "$SCRIPT_DIR/dispatch-lane.sh" release --request-id "$request_id" \
      --reason preflight_failed >/dev/null 2>&1 || true
    continue
  fi

  if ! timeout "$TRANSPORT_TIMEOUT" tmux send-keys -t "$agent" "$send_text"; then
    mark_uncertain "$request_file" "$request_id" "$cid" "$agent" \
      "task text transport failed" "$requires_qa" "$request_type" "$pipeline_id"
    continue
  fi
  if ! timeout "$TRANSPORT_TIMEOUT" tmux send-keys -t "$agent" Enter; then
    mark_uncertain "$request_file" "$request_id" "$cid" "$agent" \
      "first submit transport failed" "$requires_qa" "$request_type" "$pipeline_id"
    continue
  fi
  sleep "$SUBMIT_DELAY"
  if ! timeout "$TRANSPORT_TIMEOUT" tmux send-keys -t "$agent" Enter; then
    mark_uncertain "$request_file" "$request_id" "$cid" "$agent" \
      "second submit transport failed" "$requires_qa" "$request_type" "$pipeline_id"
    continue
  fi

  if [[ "$requires_qa" == true ]]; then
    if ! bash "$SCRIPT_DIR/qa-gate.sh" transition --request-id "$request_id" \
      --status dispatched >/dev/null 2>&1; then
      mark_uncertain "$request_file" "$request_id" "$cid" "$agent" \
        "transport succeeded but durable dispatch transition failed" \
        "$requires_qa" "$request_type" "$pipeline_id"
      continue
    fi
  elif ! mark_pipeline_delivery "$pipeline_id" "$request_id" "$agent" "$cid"; then
    mark_uncertain "$request_file" "$request_id" "$cid" "$agent" \
      "transport succeeded but pipeline delivery state failed" \
      "$requires_qa" "$request_type" "$pipeline_id"
    continue
  fi

  if ! bash "$SCRIPT_DIR/dispatch-lane.sh" transition --request-id "$request_id" \
    --status active >/dev/null 2>&1; then
    mark_uncertain "$request_file" "$request_id" "$cid" "$agent" \
      "transport succeeded but lane activation failed" \
      "$requires_qa" "$request_type" "$pipeline_id"
    continue
  fi

  log_event "$cid" dispatch "$agent" "$(echo "$task" | head -c 100)"
  reset_dispatch_failure "$agent"
  rm -f "$request_file" "$RETRY_DIR/unsupported-$request_id"
done

# Housekeeping is independent of queue depth.
bash "$SCRIPT_DIR/notification-tail.sh" 2>/dev/null || true
bash "$SCRIPT_DIR/status-snapshot.sh" >/dev/null 2>&1 || true

# Pipeline completion may release the active lane and idempotently queue a next stage.
bash "$SCRIPT_DIR/pipeline-advance.sh" >/dev/null 2>&1 || true
