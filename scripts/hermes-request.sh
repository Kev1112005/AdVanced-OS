#!/usr/bin/env bash
# hermes-request.sh — Phase 1a: workers queue an async request back toward Hermes/Kevin.
# Writes ~/.hermes/requests/<uuid>.json and returns immediately; the dispatch consumer
# routes it by type. Gated by the circuit breaker so a worker can't bypass the depth/spend
# limits by self-dispatching.
#
# Usage:
#   hermes-request <type> "<payload>" [--agent <name>] [--priority low|normal|high]
#                                     [--correlation-id <uuid:depth>]
#   <type>: research | notify | log | task   (default: task)
#
# Exit codes: 0=queued  1=circuit breaker tripped (not queued)  2=usage error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REQ_DIR="${HERMES_REQUESTS_DIR:-$HOME/.hermes/requests}"

die() { echo "error: $1" >&2; exit 2; }

type="${1:-task}"
[[ $# -ge 2 ]] || die "usage: hermes-request <type> \"<payload>\" [--agent N] [--priority P] [--correlation-id CID]"
shift
payload="$1"; shift

case "$type" in research|notify|log|task) ;; *) die "unknown type '$type' (research|notify|log|task)";; esac

agent=""
priority="normal"
in_cid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)          agent="${2:?--agent needs a value}"; shift 2 ;;
    --priority)       priority="${2:?--priority needs a value}"; shift 2 ;;
    --correlation-id) in_cid="${2:?--correlation-id needs a value}"; shift 2 ;;
    *) die "unknown arg '$1'" ;;
  esac
done
case "$priority" in low|normal|high|critical) ;; *) die "unknown priority '$priority'";; esac

# notify/research/log surface to Kevin via Hermes, not to a worker session.
[[ "$type" == task ]] || agent="hermes"
[[ -n "$agent" ]] || agent="hermes"

rid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
# Chained requests carry the depth counter so request->notify->dispatch can't bypass
# the breaker's max-depth. Root request starts at :0.
if [[ -n "$in_cid" ]]; then
  cid="$(bash "$SCRIPT_DIR/correlation-id.sh" increment "$in_cid")" || die "bad --correlation-id '$in_cid'"
else
  cid="${rid}:0"
fi

# Circuit breaker gate — if tripped, do not queue.
if ! bash "$SCRIPT_DIR/circuit-breaker.sh" check --correlation-id "$cid" >/dev/null 2>&1; then
  echo "circuit breaker tripped — request not queued" >&2
  exit 1
fi

mkdir -p "$REQ_DIR"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# python3 for JSON so the payload is escaped correctly (matches the rest of the codebase, no jq).
REQ_DIR="$REQ_DIR" REQ_ID="$rid" REQ_CID="$cid" REQ_TYPE="$type" REQ_AGENT="$agent" \
REQ_TASK="$payload" REQ_PRIO="$priority" REQ_AT="$created_at" \
python3 -c '
import json, os
o = {k: os.environ[e] for k, e in {
  "request_id":"REQ_ID","correlation_id":"REQ_CID","type":"REQ_TYPE",
  "agent":"REQ_AGENT","task":"REQ_TASK","priority":"REQ_PRIO","created_at":"REQ_AT"}.items()}
json.dump(o, open(os.path.join(os.environ["REQ_DIR"], o["request_id"]+".json"), "w"), indent=2)
' || die "failed to write request json"

bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "$cid" --event "request_$type" \
  --agent "$agent" --detail "$(echo "$payload" | head -c 100)" 2>/dev/null || true

echo "$rid"
