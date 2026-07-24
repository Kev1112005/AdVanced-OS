#!/usr/bin/env bash
# pipeline-advance.sh — idempotently advance durable serial pipeline stages.
#
# Each pipeline has its own lock and stable per-stage request IDs. A completed
# stage releases only its exact dispatch lane record, then transitions state and
# atomically ensures the next request. Safe to run standalone or from the consumer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="${HERMES_REQUESTS_DIR:-$HOME/.hermes/requests}"
PIPE_DIR="${HERMES_PIPELINE_DIR:-$HOME/.hermes/dev-pipeline}"
MIN_WORK="${HERMES_PIPELINE_MIN_WORK:-30}"
CAPTURE_DELAY="${HERMES_PIPELINE_CAPTURE_DELAY:-5}"
THINK='Spinning|Baking|Hatching|Misting|Thinking|Deliberating|Pondering|Cogitating|Accomplishing|Cascading|Channeling|Effecting|Galloping|Burrowing|Flowing|Tomfoolering'
[[ "$CAPTURE_DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || CAPTURE_DELAY=5

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }
log_ev() {
  bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$1" --event "$2" \
    --agent "$3" --detail "$4" 2>/dev/null || true
}
alert() {
  bash "$SCRIPT_DIR/hermes-alert.sh" send --level "$1" --title "$2" \
    --message "$3" >/dev/null 2>&1 || true
}

atomic_line() {
  local path="$1" value="$2" temporary
  mkdir -p "$(dirname "$path")"
  temporary="$(mktemp "${path}.tmp.XXXXXX")"
  printf '%s\n' "$value" > "$temporary"
  mv -f "$temporary" "$path"
}

stage_values() {
  case "$1" in
    researching)
      STAGE=research
      AGENT=ezekiel
      DEPTH=0
      NEXT_STATE=scaffolding
      NEXT_STAGE=scaffold
      NEXT_AGENT=sammael
      NEXT_DEPTH=1
      LINES=200
      ;;
    scaffolding)
      STAGE=scaffold
      AGENT=sammael
      DEPTH=1
      NEXT_STATE=building
      NEXT_STAGE=build
      NEXT_AGENT=claude-belial
      NEXT_DEPTH=2
      LINES=200
      ;;
    building)
      STAGE=build
      AGENT=claude-belial
      DEPTH=2
      NEXT_STATE="done"
      NEXT_STAGE=""
      NEXT_AGENT=""
      NEXT_DEPTH=0
      LINES=300
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_stage_request() {
  local pipeline_dir="$1" stage="$2" agent="$3" depth="$4"
  local pipeline_id root_cid base cid request_id sub
  pipeline_id="$(basename "$pipeline_dir")"
  root_cid="$(cat "$pipeline_dir/root_cid")"
  base="${root_cid%:*}"
  cid="$base:$depth"
  request_id="$pipeline_id-$stage"
  sub="$pipeline_dir/$stage"

  atomic_line "$sub/agent" "$agent"
  atomic_line "$sub/dispatch_cid" "$cid"
  atomic_line "$sub/request_id" "$request_id"
  mkdir -p "$REQ_DIR"

  D="$pipeline_dir" STAGE="$stage" AGENT="$agent" CID="$cid" \
    REQUEST_ID="$request_id" REQ_DIR="$REQ_DIR" NOW="$(now_iso)" python3 - <<'PY'
import json
import os
import pathlib
import tempfile

pipeline_dir = pathlib.Path(os.environ["D"])
stage = os.environ["STAGE"]
request_id = os.environ["REQUEST_ID"]
destination = pathlib.Path(os.environ["REQ_DIR"]) / f"{request_id}.json"
if destination.exists():
    raise SystemExit(0)


def read(relative):
    try:
        return (pipeline_dir / relative).read_text(encoding="utf-8")
    except OSError:
        return ""


task_md = read("task.md")
research = read("research/output.md")
scaffold = read("scaffold/output.md")
pipeline_id = pipeline_dir.name
if stage == "research":
    task = (
        f"You are working on Pipeline {pipeline_id}. Research this task: {task_md}. "
        "When done, output your structured findings in the standard Ezekiel format "
        "(Research: topic → Findings → File References → Summary → Open Questions "
        "→ Suggested Next Steps)."
    )
elif stage == "scaffold":
    task = (
        f"PIPELINE {pipeline_id} STAGE 2/3: Scaffolding\n\n"
        f"Original task:\n{task_md}\n\n"
        f"Ezekiel's research findings:\n{research}\n\n"
        "Build the baseline framework for this task. When done, output a Vanguard "
        "Handoff Directive (tactical objective, architectural layout, precise file "
        "paths, design boundaries)."
    )
else:
    task = (
        f"PIPELINE {pipeline_id} STAGE 3/3: Building\n\n"
        f"Original task:\n{task_md}\n\n"
        f"Ezekiel's research findings:\n{research}\n\n"
        f"Sammael's scaffold / handoff directive:\n{scaffold}\n\n"
        "Implement and test the full solution. Build on the scaffold above; fill in "
        "the deep implementation and verify it works."
    )
request = {
    "request_id": request_id,
    "correlation_id": os.environ["CID"],
    "agent": os.environ["AGENT"],
    "task": task,
    "priority": "normal",
    "type": "pipeline",
    "pipeline_id": pipeline_id,
    "created_at": os.environ["NOW"],
}
fd, temp_name = tempfile.mkstemp(
    prefix=f".{destination.name}.", dir=destination.parent
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(request, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_name, destination)
finally:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass
PY
  if [[ ! -f "$sub/queued_at" ]]; then
    atomic_line "$sub/queued_at" "$(now_iso)"
    log_ev "$cid" queued "$agent" "pipeline $stage queued"
  fi
}

capture_output() {
  local agent="$1" lines="$2" destination="$3" temporary
  temporary="$(mktemp "${destination}.tmp.XXXXXX")"
  if ! tmux capture-pane -t "$agent" -p -S "-$lines" > "$temporary" 2>/dev/null; then
    rm -f "$temporary"
    return 1
  fi
  mv -f "$temporary" "$destination"
}

generate_report() {
  local pipeline_dir="$1"
  D="$pipeline_dir" python3 - <<'PY'
import os
import pathlib
import tempfile

directory = pathlib.Path(os.environ["D"])


def read(relative):
    try:
        return (directory / relative).read_text(encoding="utf-8")
    except OSError:
        return "(none)"


output = (
    f"# Pipeline Report: {read('name').strip()}\n\n"
    f"## Original Task\n{read('task.md')}\n\n"
    f"## Research (Ezekiel)\n{read('research/output.md')}\n\n"
    f"## Scaffold (Sammael)\n{read('scaffold/output.md')}\n\n"
    f"## Build (Belial)\n{read('build/output.md')}\n"
)
destination = directory / "report.md"
fd, temp_name = tempfile.mkstemp(prefix=f".{destination.name}.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(output)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temp_name, destination)
finally:
    try:
        os.unlink(temp_name)
    except FileNotFoundError:
        pass
PY
}

process_pipeline() (
  local pipeline_dir="$1" state root_cid sub request_id pane now
  exec 8>"$pipeline_dir/.advance.lock"
  flock -n 8 || exit 0

  state="$(cat "$pipeline_dir/state" 2>/dev/null || true)"
  stage_values "$state" || exit 0
  root_cid="$(cat "$pipeline_dir/root_cid" 2>/dev/null || true)"
  [[ -n "$root_cid" ]] || exit 0
  sub="$pipeline_dir/$STAGE"
  mkdir -p "$sub"

  # Recovery after a state transition but before request publication.
  if [[ ! -f "$sub/sent_at" ]]; then
    ensure_stage_request "$pipeline_dir" "$STAGE" "$AGENT" "$DEPTH"
    exit 0
  fi

  # Recover a completed capture whose timestamp write was interrupted.
  if [[ -f "$sub/output.md" && ! -f "$sub/completed_at" ]]; then
    atomic_line "$sub/completed_at" "$(now_iso)"
  fi

  if [[ ! -f "$sub/completed_at" ]]; then
    if (( $(date +%s) - $(epoch "$(cat "$sub/sent_at")") < MIN_WORK )); then
      exit 0
    fi

    if [[ "$(bash "$SCRIPT_DIR/heartbeat-check.sh" status "$AGENT" 2>/dev/null)" == stuck ]]; then
      atomic_line "$pipeline_dir/state" failed
      log_ev "$root_cid" fail "$AGENT" "pipeline $STAGE stuck"
      alert alert "Pipeline stalled" \
        "Agent $AGENT wedged during $STAGE in pipeline '$(cat "$pipeline_dir/name" 2>/dev/null)'."
      exit 0
    fi

    pane="$(tmux capture-pane -t "$AGENT" -p -S -6 2>/dev/null)" || exit 0
    grep -qE "$THINK" <<<"$pane" && exit 0
    grep -qE '❯|⏵⏵' <<<"$pane" || exit 0
    grep -qE 'msg=interrupt|Ctrl\+C cancel|reasoning\.\.\.' <<<"$pane" && exit 0

    sleep "$CAPTURE_DELAY"
    capture_output "$AGENT" "$LINES" "$sub/output.md" || exit 0
    atomic_line "$sub/completed_at" "$(now_iso)"
    log_ev "$root_cid" complete "$AGENT" "pipeline $STAGE captured"
  fi

  request_id="$(cat "$sub/request_id" 2>/dev/null || true)"
  [[ -n "$request_id" ]] || {
    log_ev "$root_cid" fail "$AGENT" "pipeline $STAGE missing request_id"
    exit 0
  }
  if ! bash "$SCRIPT_DIR/dispatch-lane.sh" release --request-id "$request_id" \
    --reason pipeline_complete >/dev/null 2>&1; then
    log_ev "$root_cid" fail "$AGENT" \
      "pipeline $STAGE completion cannot release a different active lane"
    exit 0
  fi

  if [[ -n "$NEXT_STAGE" ]]; then
    atomic_line "$pipeline_dir/$NEXT_STAGE/agent" "$NEXT_AGENT"
    atomic_line "$pipeline_dir/$NEXT_STAGE/dispatch_cid" \
      "${root_cid%:*}:$NEXT_DEPTH"
    atomic_line "$pipeline_dir/$NEXT_STAGE/request_id" \
      "$(basename "$pipeline_dir")-$NEXT_STAGE"
    atomic_line "$pipeline_dir/state" "$NEXT_STATE"
    ensure_stage_request "$pipeline_dir" "$NEXT_STAGE" "$NEXT_AGENT" "$NEXT_DEPTH"
  else
    generate_report "$pipeline_dir"
    atomic_line "$pipeline_dir/state" "done"
    now="$(now_iso)"
    atomic_line "$pipeline_dir/completed_at" "$now"
    log_ev "$root_cid" complete "$AGENT" \
      "pipeline done: $(cat "$pipeline_dir/name" 2>/dev/null)"
  fi
)

[[ -d "$PIPE_DIR" ]] || exit 0
for candidate in "$PIPE_DIR"/*/; do
  [[ -f "$candidate/state" ]] || continue
  process_pipeline "${candidate%/}" || true
done
