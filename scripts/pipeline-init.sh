#!/usr/bin/env bash
# pipeline-init.sh — start a dev pipeline: create state + dispatch research to Ezekiel.
# Usage: pipeline-init.sh <name> <task-description>
# Prints the pipeline UUID to stdout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="${HERMES_REQUESTS_DIR:-$HOME/.hermes/requests}"
PIPE_DIR="${HERMES_PIPELINE_DIR:-$HOME/.hermes/dev-pipeline}"

name="${1:-}"; task="${2:-}"
[[ -z "${name// /}" ]] && { echo "error: pipeline name required" >&2; exit 1; }
[[ -z "${task// /}" ]] && { echo "error: task description required" >&2; exit 1; }

uuid="$(python3 -c 'import uuid; print(uuid.uuid4())')"
dir="$PIPE_DIR/$uuid"
mkdir -p "$dir/research" "$dir/scaffold" "$dir/build" "$REQ_DIR"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
request_id="$uuid-research"

printf '%s' "researching" > "$dir/state"
printf '%s' "$name"       > "$dir/name"
printf '%s' "$task"       > "$dir/task.md"
printf '%s' "$now"        > "$dir/created_at"
printf '%s' "$uuid:0"     > "$dir/root_cid"
printf '%s' "ezekiel"     > "$dir/research/agent"
printf '%s' "$uuid:0"     > "$dir/research/dispatch_cid"
printf '%s' "$request_id"  > "$dir/research/request_id"
# ponytail: sent_at is written by dispatch-consumer on actual delivery, NOT here —
# writing it at init would let pipeline-advance capture empty output before the task lands.

ctx="You are working on Pipeline $uuid. Research this task: $task. When done, output your structured findings in the standard Ezekiel format (Research: topic → Findings → File References → Summary → Open Questions → Suggested Next Steps)."

REQ_DIR="$REQ_DIR" UUID="$uuid" REQUEST_ID="$request_id" NOW="$now" CTX="$ctx" python3 - <<'PY'
import json
import os
import tempfile

rid = os.environ["REQUEST_ID"]
req = {"request_id": rid, "correlation_id": f"{rid}:0", "agent": "ezekiel",
       "task": os.environ['CTX'], "priority": "normal", "type": "pipeline",
       "pipeline_id": os.environ["UUID"], "created_at": os.environ['NOW']}
req["correlation_id"] = f"{os.environ['UUID']}:0"
destination = os.path.join(os.environ["REQ_DIR"], f"{rid}.json")
fd, temporary = tempfile.mkstemp(
    prefix=f".{os.path.basename(destination)}.", dir=os.path.dirname(destination)
)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(req, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, destination)
finally:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
PY

bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$uuid:0" --event start \
  --agent ezekiel --detail "pipeline start: $name" 2>/dev/null || true

echo "$uuid"
