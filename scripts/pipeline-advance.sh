#!/usr/bin/env bash
# pipeline-advance.sh — detect completed pipeline stages, capture output, dispatch next stage.
# Called by dispatch-consumer.sh at the end of each poll (and safe to run standalone).
# No jq; python3 for JSON + task assembly. One stage advance per pipeline per run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="${HERMES_REQUESTS_DIR:-$HOME/.hermes/requests}"
PIPE_DIR="${HERMES_PIPELINE_DIR:-$HOME/.hermes/dev-pipeline}"
MIN_WORK="${HERMES_PIPELINE_MIN_WORK:-30}"   # seconds after sent_at before "idle" counts as done

# Full thinking-indicator set (superset of heartbeat's) — Hermes + Claude Code spinners.
THINK='Spinning|Baking|Hatching|Misting|Thinking|Deliberating|Pondering|Cogitating|Accomplishing|Cascading|Channeling|Effecting|Galloping|Burrowing|Flowing|Tomfoolering'

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch()   { date -u -d "$1" +%s 2>/dev/null || echo 0; }
log_ev()  { bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$1" --event "$2" --agent "$3" --detail "$4" 2>/dev/null || true; }
alert()   { bash "$SCRIPT_DIR/hermes-alert.sh" send --level "$1" --title "$2" --message "$3" >/dev/null 2>&1 || true; }

# Assemble + queue the next stage's dispatch (scaffold or build). Reads accumulated
# outputs so the downstream agent gets full context. args: dir rcid ncid nagent nsub
create_next_dispatch() {
  local d="$1" rcid="$2" ncid="$3" nagent="$4" nsub="$5" nuuid
  nuuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  D="$d" RCID="$rcid" NCID="$ncid" NUUID="$nuuid" NAGENT="$nagent" NSUB="$nsub" \
  REQ_DIR="$REQ_DIR" NOW="$(now_iso)" python3 - <<'PY'
import json, os
d = os.environ['D']; nsub = os.environ['NSUB']; rcid = os.environ['RCID']
def rd(p):
    try:
        with open(os.path.join(d, p), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""
task_md = rd('task.md'); research = rd('research/output.md'); scaffold = rd('scaffold/output.md')
if nsub == 'scaffold':
    task = (f"PIPELINE {rcid} STAGE 2/3: Scaffolding\n\n"
            f"Original task:\n{task_md}\n\n"
            f"Ezekiel's research findings:\n{research}\n\n"
            "Build the baseline framework for this task. When done, output a Vanguard "
            "Handoff Directive (tactical objective, architectural layout, precise file "
            "paths, design boundaries).")
else:  # build
    task = (f"PIPELINE {rcid} STAGE 3/3: Building\n\n"
            f"Original task:\n{task_md}\n\n"
            f"Ezekiel's research findings:\n{research}\n\n"
            f"Sammael's scaffold / handoff directive:\n{scaffold}\n\n"
            "Implement and test the full solution. Build on the scaffold above; fill in "
            "the deep implementation and verify it works.")
rid = os.environ['NUUID']
req = {"request_id": rid, "correlation_id": os.environ['NCID'], "agent": os.environ['NAGENT'],
       "task": task, "priority": "normal", "type": "pipeline",
       "pipeline_id": os.path.basename(d.rstrip('/')), "created_at": os.environ['NOW']}
with open(os.path.join(os.environ['REQ_DIR'], f"{rid}.json"), "w", encoding="utf-8") as f:
    json.dump(req, f, indent=2)
PY
  printf '%s' "$nagent" > "$d/$nsub/agent"
  printf '%s' "$ncid"   > "$d/$nsub/dispatch_cid"
}

generate_report() {
  local d="$1"
  D="$d" python3 - <<'PY'
import os
d = os.environ['D']
def rd(p):
    try:
        with open(os.path.join(d, p), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return "(none)"
name = rd('name').strip()
out = (f"# Pipeline Report: {name}\n\n"
       f"## Original Task\n{rd('task.md')}\n\n"
       f"## Research (Ezekiel)\n{rd('research/output.md')}\n\n"
       f"## Scaffold (Sammael)\n{rd('scaffold/output.md')}\n\n"
       f"## Build (Belial)\n{rd('build/output.md')}\n")
with open(os.path.join(d, 'report.md'), 'w', encoding="utf-8") as f:
    f.write(out)
PY
}

[[ -d "$PIPE_DIR" ]] || exit 0

for dir in "$PIPE_DIR"/*/; do
  [[ -f "$dir/state" ]] || continue
  dir="${dir%/}"
  state="$(cat "$dir/state")"
  root_cid="$(cat "$dir/root_cid" 2>/dev/null || echo)"
  base="${root_cid%:*}"

  case "$state" in
    researching) stage=research; agent=ezekiel;      next_sub=scaffold; next_agent=sammael;       next_state=scaffolding; next_n=1; lines=200 ;;
    scaffolding) stage=scaffold; agent=sammael;      next_sub=build;    next_agent=claude-belial; next_state=building;    next_n=2; lines=200 ;;
    building)    stage=build;    agent=claude-belial; next_sub="";      next_agent="";            next_state=done;        next_n=0; lines=300 ;;
    *) continue ;;   # done | failed | unknown — nothing to advance
  esac

  sub="$dir/$stage"
  [[ -f "$sub/sent_at" ]]  || continue   # consumer hasn't delivered this stage yet
  [[ -f "$sub/output.md" ]] && continue   # already captured

  # Minimum work-time guard: don't capture a just-dispatched agent that looks idle.
  (( $(date +%s) - $(epoch "$(cat "$sub/sent_at")") < MIN_WORK )) && continue

  # Stuck (heartbeat) → fail the pipeline and alert, don't advance.
  if [[ "$(bash "$SCRIPT_DIR/heartbeat-check.sh" status "$agent" 2>/dev/null)" == stuck ]]; then
    printf '%s' failed > "$dir/state"
    log_ev "$root_cid" fail "$agent" "pipeline $stage stuck"
    alert alert "Pipeline stalled" "Agent $agent wedged during the $stage stage of pipeline '$(cat "$dir/name" 2>/dev/null)'. Marked failed."
    continue
  fi

  # Busy thinking, or not back at a prompt yet → wait for the next poll.
  pane="$(tmux capture-pane -t "$agent" -p -S -6 2>/dev/null)" || continue
  grep -qE "$THINK" <<<"$pane" && continue
  grep -qE '❯|⏵⏵'   <<<"$pane" || continue
  # Hermes agents show a `⚕ ❯ ... Ctrl+C cancel` busy footer whose ❯ matches above; skip it.
  grep -qE 'msg=interrupt|Ctrl\+C cancel|reasoning\.\.\.' <<<"$pane" && continue

  # Idle & settled: let the pane flush, then capture the full report.
  sleep 5
  tmux capture-pane -t "$agent" -p -S -"$lines" 2>/dev/null > "$sub/output.md" || continue
  now_iso > "$sub/completed_at"
  log_ev "$root_cid" complete "$agent" "pipeline $stage captured"

  if [[ -n "$next_sub" ]]; then
    create_next_dispatch "$dir" "$root_cid" "$base:$next_n" "$next_agent" "$next_sub"
    printf '%s' "$next_state" > "$dir/state"
    log_ev "$base:$next_n" dispatch "$next_agent" "pipeline advance → $next_state"
  else
    printf '%s' done > "$dir/state"
    generate_report "$dir"
    log_ev "$root_cid" complete "$agent" "pipeline done: $(cat "$dir/name" 2>/dev/null)"
  fi
done
