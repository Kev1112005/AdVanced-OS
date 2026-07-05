#!/usr/bin/env bash
# cron-failure-monitor.sh — track consecutive cron job failures and alert on threshold.
# Signal source for Feature Gap 1.1: cron jobs report exit codes here; N consecutive
# failures fire a Discord alert via hermes-alert.sh. A single success clears the counter.
#
#   cron-failure-monitor.sh wrap   --job NAME -- command [args...]   Run cmd, track its exit code
#   cron-failure-monitor.sh report --job NAME --exit-code N          Report an already-run job
#   cron-failure-monitor.sh status --job NAME                        Print one job's failure count
#   cron-failure-monitor.sh status --all                            Print all tracked jobs
#
# ponytail: plain read/write on state files — Hermes runs serial crons that don't
# overlap by name, so no flock. Add per-job flock if concurrent same-name jobs appear.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CB_CONFIG="$SCRIPT_DIR/../config/circuit-breaker.yaml"
STATE_ROOT="${HERMES_ALERT_STATE:-$HOME/.hermes/alerts}/cron-failures"

THRESHOLD="$(grep -E '^[[:space:]]*cron_failure_threshold:' "$CB_CONFIG" 2>/dev/null \
  | head -n1 | sed -E 's/.*:[[:space:]]*//; s/[[:space:]]*#.*$//')"
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || THRESHOLD=3

# job names become directory names — reject anything but [A-Za-z0-9_-] (no injection, no traversal)
sanitize_job() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "error: invalid job name '$1' (allowed: A-Za-z0-9_-)" >&2; exit 1; }
  printf '%s' "$1"
}

log_event() {  # best-effort trend log; never fails the caller
  bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "cron:0" \
    --event "$1" --agent "$2" --detail "$3" 2>/dev/null || true
}

alert() {  # $1=job $2=count $3=exit-code
  bash "$SCRIPT_DIR/hermes-alert.sh" send --level alert \
    --title "Cron job failing: $1" \
    --message "$2 consecutive failures for cron job '$1'. Last exit code: $3. Check the logs." \
    2>/dev/null || true
}

# core: apply an exit code to a job's failure state
record() {  # $1=job $2=exit-code
  local job="$1" code="$2" dir="$STATE_ROOT/$1"
  mkdir -p "$dir"
  if [[ "$code" -eq 0 ]]; then
    rm -f "$dir/count" "$dir/alerted"
    log_event cron_ok "$job" "success — failure counter reset"
    return
  fi
  local count=$(( $(cat "$dir/count" 2>/dev/null || echo 0) + 1 ))
  echo "$count" > "$dir/count"
  if (( count >= THRESHOLD )) && [[ ! -f "$dir/alerted" ]]; then
    alert "$job" "$count" "$code"
    touch "$dir/alerted"
    log_event cron_alert "$job" "$count consecutive failures (exit $code) — alert fired"
  else
    log_event cron_fail "$job" "failure #$count (exit $code, threshold $THRESHOLD)"
  fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  wrap)
    job=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --job) job="$(sanitize_job "${2:?--job needs a value}")"; shift 2 ;;
        --) shift; break ;;
        *) echo "error: unknown arg '$1' (expected --job then -- command)" >&2; exit 1 ;;
      esac
    done
    [[ -n "$job" ]] || { echo "error: --job required" >&2; exit 1; }
    [[ $# -gt 0 ]] || { echo "error: no command after --" >&2; exit 1; }
    set +e; "$@"; code=$?; set -e
    record "$job" "$code"
    exit "$code"
    ;;

  report)
    job="" code=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --job)       job="$(sanitize_job "${2:?--job needs a value}")"; shift 2 ;;
        --exit-code) code="${2:?--exit-code needs a value}"; shift 2 ;;
        *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
      esac
    done
    [[ -n "$job" && -n "$code" ]] || { echo "error: --job and --exit-code required" >&2; exit 1; }
    [[ "$code" =~ ^[0-9]+$ ]] || { echo "error: --exit-code must be a number" >&2; exit 1; }
    record "$job" "$code"
    ;;

  status)
    if [[ "${1:-}" == "--all" ]]; then
      [[ -d "$STATE_ROOT" ]] || { echo "No cron jobs tracked yet"; exit 0; }
      shopt -s nullglob
      for d in "$STATE_ROOT"/*/; do
        j="$(basename "$d")"
        printf '%s\t%s%s\n' "$j" "$(cat "$d/count" 2>/dev/null || echo 0)" \
          "$([[ -f "$d/alerted" ]] && echo ' (alerted)')"
      done
    elif [[ "${1:-}" == "--job" ]]; then
      job="$(sanitize_job "${2:?--job needs a value}")"
      cat "$STATE_ROOT/$job/count" 2>/dev/null || echo 0
    else
      echo "usage: cron-failure-monitor.sh status --job NAME | --all" >&2; exit 1
    fi
    ;;

  -h|--help|help|"")
    grep -E '^#( |$)' "$0" | sed -E 's/^# ?//'
    ;;
  *)
    echo "error: unknown command '$cmd'" >&2; exit 1 ;;
esac
