#!/usr/bin/env bash
# cost-log.sh — Phase 1c: append-only cost log + weekly summary.
# CSV columns: timestamp,correlation_id,model,input_tokens,output_tokens,cache_read,cache_write,cost_usd,task
#
# Exit codes: 0 success, 1 usage/error
set -euo pipefail

DEFAULT_LOG="${HERMES_COST_LOG:-$HOME/.hermes/logs/cost-log.csv}"
CAP="${HERMES_WEEKLY_CAP:-20.0}"
HEADER="timestamp,correlation_id,model,input_tokens,output_tokens,cache_read,cache_write,cost_usd,task"

usage() {
  cat <<EOF
cost-log.sh — record and summarize Claude Code usage

Usage:
  cost-log.sh log --correlation-id ID --model M --input-tokens N --output-tokens N \\
      [--cache-read N] [--cache-write N] --cost-usd U --task "..." [--log PATH]
  cost-log.sh summary [--log PATH]     JSON: total_spend, cap, remaining, task_count, by_worker
  cost-log.sh recent [--limit N] [--log PATH]   Tabular: timestamp | cid | model | cost | task

Default log: $DEFAULT_LOG   (env HERMES_COST_LOG, HERMES_WEEKLY_CAP)
EOF
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# strip commas/newlines from a field so one row stays one row
clean() { echo "${1//[,$'\n\r']/ }"; }

ensure_log() {
  local log="$1"
  if [[ ! -f "$log" ]]; then
    mkdir -p "$(dirname "$log")"
    echo "$HEADER" > "$log"
  fi
}

# epoch of the start of the current week (Mon 00:00 local)
week_start() { date -d "$(date +%Y-%m-%d) -$(( ($(date +%u) + 6) % 7 )) days" +%s; }

cmd="${1:-}"
shift || true

case "$cmd" in
  log)
    cid="" model="" in_tok=0 out_tok=0 cache_r=0 cache_w=0 cost="" task="" log="$DEFAULT_LOG"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --correlation-id) cid="$2"; shift 2 ;;
        --model)          model="$2"; shift 2 ;;
        --input-tokens)   in_tok="$2"; shift 2 ;;
        --output-tokens)  out_tok="$2"; shift 2 ;;
        --cache-read)     cache_r="$2"; shift 2 ;;
        --cache-write)    cache_w="$2"; shift 2 ;;
        --cost-usd)       cost="$2"; shift 2 ;;
        --task)           task="$2"; shift 2 ;;
        --log)            log="$2"; shift 2 ;;
        *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
      esac
    done
    [[ -n "$cid" && -n "$model" && -n "$cost" ]] || {
      echo "error: --correlation-id, --model, --cost-usd required" >&2; exit 1; }
    ensure_log "$log"
    echo "$(now_utc),$(clean "$cid"),$(clean "$model"),$in_tok,$out_tok,$cache_r,$cache_w,$cost,$(clean "$task")" >> "$log"
    echo "logged: $cid $model \$$cost -> $log"
    ;;

  summary)
    log="$DEFAULT_LOG"
    [[ "${1:-}" == "--log" ]] && { log="$2"; shift 2; }
    if [[ ! -f "$log" ]]; then
      printf '{"total_spend":0.00,"cap":%.2f,"remaining":%.2f,"task_count":0,"by_worker":{}}\n' "$CAP" "$CAP"
      exit 0
    fi
    awk -F',' -v ws="$(week_start)" -v cap="$CAP" '
      NR==1 { next }
      {
        ts=$1; gsub("T"," ",ts); gsub("Z","",ts)
        cmd="date -u -d \"" ts " UTC\" +%s 2>/dev/null"; cmd | getline e; close(cmd)
        if (e=="" || e+0 < ws) next
        total += $8; count++
        # worker = model family prefix before first "-" (claude-opus-4.8 -> claude), fallback whole model
        w=$3
        spend[w]+=$8; tasks[w]++
      }
      END {
        printf "{\"total_spend\":%.2f,\"cap\":%.2f,\"remaining\":%.2f,\"task_count\":%d,\"by_worker\":{",
               total+0, cap+0, cap-total, count+0
        first=1
        for (w in spend) {
          printf "%s\"%s\":{\"spend\":%.2f,\"tasks\":%d}", (first?"":","), w, spend[w], tasks[w]
          first=0
        }
        print "}}"
      }
    ' "$log"
    ;;

  recent)
    limit=5 log="$DEFAULT_LOG"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --limit) limit="$2"; shift 2 ;;
        --log)   log="$2"; shift 2 ;;
        *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
      esac
    done
    [[ -f "$log" ]] || { echo "no log yet: $log" >&2; exit 1; }
    printf '%-21s | %-40s | %-16s | %-7s | %s\n' timestamp correlation_id model cost task
    tail -n +2 "$log" | tail -n "$limit" | awk -F',' '
      { printf "%-21s | %-40s | %-16s | %-7s | %s\n", $1, $2, $3, $8, $9 }'
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
