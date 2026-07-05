#!/usr/bin/env bash
# circuit-breaker.sh — Phase 2: the gate before every dispatch.
# Decision 002: "Circuit breaker before accelerator." All automation gated here.
#
# Checks in order: global stop -> dispatch depth -> spend cap.
# Exit codes: 0=PASS, 1=global stop, 2=depth limit, 3=spend cap, 4=config error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/../config/circuit-breaker.yaml"

usage() {
  cat <<EOF
circuit-breaker.sh — pre-dispatch safety gate

Usage:
  circuit-breaker.sh check --correlation-id <uuid:depth> [--config <path>]

Exit codes: 0=PASS  1=global stop  2=depth limit  3=spend cap  4=config error
EOF
}

# expand a leading ~ to \$HOME (config values are written with ~ for readability)
expand_home() { echo "${1/#\~/$HOME}"; }

# read a flat key's value from the simple YAML (grep first match, strip comments/quotes)
yaml_get() {
  local key="$1" file="$2"
  # `|| true` so an absent key doesn't fail the pipeline under `set -o pipefail`
  # (grep exits 1 on no match), which would kill the script before a :-default applies.
  { grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null || true; } | head -n1 \
    | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^\"//; s/\"$//"
}

# sum cost_usd (col 8) for rows whose timestamp (col 1) is >= start of the current week (Mon 00:00 local)
weekly_spend() {
  local log="$1"
  [[ -f "$log" ]] || { echo "0"; return; }
  local week_start
  # days since Monday: (dow+6)%7, where date +%u is 1..7 (Mon..Sun)
  week_start=$(date -d "$(date +%Y-%m-%d) -$(( ($(date +%u) + 6) % 7 )) days" +%s)
  awk -F',' -v ws="$week_start" '
    NR==1 { next }                                   # header
    {
      ts=$1; gsub("T"," ",ts); gsub("Z","",ts)       # ISO -> "date time" for date(1)
      cmd="date -u -d \"" ts " UTC\" +%s 2>/dev/null"
      cmd | getline e; close(cmd)
      if (e != "" && e+0 >= ws) sum += $8
    }
    END { printf "%.2f", sum+0 }
  ' "$log"
}

# Fire a Discord alert when weekly spend first crosses a warn/alert/critical threshold.
# A flag file per level per ISO week stops re-firing on every poll. Highest crossed
# level wins; lower levels are marked fired so they don't alert separately later.
spend_threshold_alerts() {
  local spend="$1" cap="$2" pct level gate week flag
  pct="$(awk -v s="$spend" -v c="$cap" 'BEGIN{printf "%.0f", (c+0>0)? s/c*100 : 0}')"
  if   (( pct >= CRIT_PCT ));  then level=critical; gate=$CRIT_PCT
  elif (( pct >= ALERT_PCT )); then level=alert;    gate=$ALERT_PCT
  elif (( pct >= WARN_PCT ));  then level=warn;     gate=$WARN_PCT
  else return 0
  fi
  week="$(date +%G-W%V)"
  flag="$ALERT_STATE_DIR/spend-$week-$level.flag"
  [[ -f "$flag" ]] && return 0
  mkdir -p "$ALERT_STATE_DIR"
  case "$level" in
    critical) touch "$ALERT_STATE_DIR/spend-$week-warn.flag" "$ALERT_STATE_DIR/spend-$week-alert.flag" "$ALERT_STATE_DIR/spend-$week-critical.flag" ;;
    alert)    touch "$ALERT_STATE_DIR/spend-$week-warn.flag" "$ALERT_STATE_DIR/spend-$week-alert.flag" ;;
    warn)     touch "$ALERT_STATE_DIR/spend-$week-warn.flag" ;;
  esac
  bash "$SCRIPT_DIR/hermes-alert.sh" send --level "$level" \
    --title "Weekly spend ${pct}% of cap" \
    --message "Spend \$${spend} of \$${cap} (${pct}%). ${gate}% threshold crossed." \
    --config "$CONFIG" >/dev/null 2>&1 || true
}

[[ "${1:-}" == "check" ]] || { usage; [[ "${1:-}" =~ ^(-h|--help|help|)$ ]] && exit 0 || exit 4; }
shift

CID=""
CONFIG="$DEFAULT_CONFIG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --correlation-id) CID="${2:?--correlation-id needs a value}"; shift 2 ;;
    --config)         CONFIG="${2:?--config needs a value}"; shift 2 ;;
    *) echo "error: unknown arg '$1'" >&2; exit 4 ;;
  esac
done
[[ -n "$CID" ]] || { echo '{"status":"ERROR","error":"--correlation-id required"}'; exit 4; }
[[ -f "$CONFIG" ]] || { echo "{\"status\":\"ERROR\",\"error\":\"config not found: $CONFIG\"}"; exit 4; }

# --- load config ---
STOP_FILE="$(yaml_get flag_file "$CONFIG")";     STOP_FILE="$(expand_home "${STOP_FILE:-$HOME/.hermes/stop}")"
MAX_DEPTH="$(yaml_get max "$CONFIG")";            MAX_DEPTH="${MAX_DEPTH:-3}"
CAP="$(yaml_get weekly_usd "$CONFIG")";           CAP="${CAP:-20.0}"
LOG_FILE="$(yaml_get log_file "$CONFIG")";        LOG_FILE="$(expand_home "${LOG_FILE:-$HOME/.hermes/logs/cost-log.csv}")"
WARN_PCT="$(yaml_get warn_at_pct "$CONFIG")";     WARN_PCT="${WARN_PCT:-50}"
ALERT_PCT="$(yaml_get alert_at_pct "$CONFIG")";   ALERT_PCT="${ALERT_PCT:-75}"
CRIT_PCT="$(yaml_get critical_at_pct "$CONFIG")"; CRIT_PCT="${CRIT_PCT:-90}"
ALERT_STATE_DIR="${HERMES_ALERT_STATE:-$HOME/.hermes/alerts}"

# --- 1. global stop ---
if [[ -f "$STOP_FILE" ]]; then
  echo '{"status":"FAIL","blocked_by":"global_stop","detail":"Global stop flag set"}'
  echo "BLOCKED: Global stop flag set" >&2
  exit 1
fi

# --- 2. dispatch depth (use correlation-id.sh to parse) ---
depth="$(bash "$SCRIPT_DIR/correlation-id.sh" parse "$CID" | sed -n 's/.*DEPTH=//p')" \
  || { echo "{\"status\":\"ERROR\",\"error\":\"bad correlation id: $CID\"}"; exit 4; }
if [[ "$depth" -ge "$MAX_DEPTH" ]]; then
  printf '{"status":"FAIL","blocked_by":"dispatch_depth","detail":{"current":%d,"max":%d}}\n' "$depth" "$MAX_DEPTH"
  echo "BLOCKED: Dispatch depth limit reached ($MAX_DEPTH)" >&2
  exit 2
fi

# --- 3. spend cap ---
spend="$(weekly_spend "$LOG_FILE")"
spend_threshold_alerts "$spend" "$CAP"   # warn/alert/critical before the hard block
if awk -v s="$spend" -v c="$CAP" 'BEGIN{exit !(s+0 >= c+0)}'; then
  printf '{"status":"FAIL","blocked_by":"spend_cap","detail":{"weekly_spend":%.2f,"cap":%.2f}}\n' "$spend" "$CAP"
  echo "BLOCKED: Weekly spend cap reached (\$$spend/\$$CAP)" >&2
  exit 3
fi

# --- PASS ---
printf '{"status":"PASS","checks":{"global_stop":true,"dispatch_depth":{"current":%d,"max":%d,"status":"PASS"},"spend_cap":{"weekly_spend":%.2f,"cap":%.2f,"status":"PASS"}}}\n' \
  "$depth" "$MAX_DEPTH" "$spend" "$CAP"
exit 0
