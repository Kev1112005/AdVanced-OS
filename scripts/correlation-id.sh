#!/usr/bin/env bash
# correlation-id.sh — Phase 1b: correlation ID + depth counter
# Format: <uuid>:<depth>  (colon-separated). Depth 0 = root dispatch.
#
# Exit codes:
#   0  success (or check-depth: AT/ABOVE max — blocked)
#   1  check-depth: under max — allowed  /  or usage error
set -euo pipefail

usage() {
  cat <<'EOF'
correlation-id.sh — correlation ID with depth counter

Usage:
  correlation-id.sh generate                 New root ID -> <uuid>:0
  correlation-id.sh increment <id>           Bump depth -> <uuid>:<d+1>
  correlation-id.sh parse <id>               -> UUID=<uuid> DEPTH=<d>
  correlation-id.sh check-depth <id> --max N Exit 0 if depth>=N (blocked), 1 if allowed

Exit codes: 0=ok/blocked, 1=allowed/usage error
EOF
}

# Split "<uuid>:<depth>" into globals UUID and DEPTH. Fails on malformed input.
parse_id() {
  local id="$1"
  UUID="${id%:*}"
  DEPTH="${id##*:}"
  if [[ "$id" != *:* ]] || [[ -z "$UUID" ]] || ! [[ "$DEPTH" =~ ^[0-9]+$ ]]; then
    echo "error: malformed correlation ID: '$id' (expected <uuid>:<depth>)" >&2
    return 1
  fi
}

cmd="${1:-}"
case "$cmd" in
  generate)
    echo "$(uuidgen):0"
    ;;
  increment)
    parse_id "${2:?increment needs an id}"
    echo "${UUID}:$((DEPTH + 1))"
    ;;
  parse)
    parse_id "${2:?parse needs an id}"
    echo "UUID=${UUID} DEPTH=${DEPTH}"
    ;;
  check-depth)
    parse_id "${2:?check-depth needs an id}"
    max=""
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --max) max="${2:?--max needs a value}"; shift 2 ;;
        *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
      esac
    done
    [[ "$max" =~ ^[0-9]+$ ]] || { echo "error: --max <N> required" >&2; exit 1; }
    # blocked (exit 0) when at or above max
    [[ "$DEPTH" -ge "$max" ]]
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "error: unknown command '$cmd'" >&2
    usage >&2
    exit 1
    ;;
esac
