#!/usr/bin/env bash
# status-snapshot.sh — Phase 5b: write a JSON snapshot of system state.
# Polled by the dashboard via /api/status. Reuses Day 1 scripts for spend + stop.
#
# Exit codes: 0 success, 1 error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_FILE="${HERMES_STATUS_FILE:-$HOME/.hermes/status/current.json}"
MAX_DEPTH="${HERMES_MAX_DEPTH:-3}"
SESSION="claude-belial"

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# pull a numeric field out of cost-log.sh's summary JSON (no jq dependency)
json_num() { sed -n "s/.*\"$1\":\([0-9.-]*\).*/\1/p" <<<"$2" | head -n1; }

# --- spend (from Day 1 cost-log summary) ---
summary="$(bash "$SCRIPT_DIR/cost-log.sh" summary 2>/dev/null || echo '{}')"
weekly="$(json_num total_spend "$summary")"; weekly="${weekly:-0}"
cap="$(json_num cap "$summary")";            cap="${cap:-20.0}"
remaining="$(json_num remaining "$summary")"; remaining="${remaining:-$cap}"
pct="$(awk -v s="$weekly" -v c="$cap" 'BEGIN{ printf "%.1f", (c+0>0)? s/c*100 : 0 }')"

# --- global stop (from Day 1 global-stop) ---
if bash "$SCRIPT_DIR/global-stop.sh" check >/dev/null 2>&1; then
  global_stop="true"
else
  global_stop="false"
fi

# --- circuit breaker rollup ---
if [[ "$global_stop" == "true" ]] || awk -v s="$weekly" -v c="$cap" 'BEGIN{exit !(s+0>=c+0)}'; then
  cb_status="TRIPPED"
else
  cb_status="PASS"
fi

# --- worker liveness (tmux) ---
if ! command -v tmux >/dev/null 2>&1; then
  worker_status="unknown"
elif tmux has-session -t "$SESSION" 2>/dev/null; then
  worker_status="idle"
else
  worker_status="dead"
fi

# --- cron jobs: static list (updated manually when jobs change; see spec) ---
ts="$(now_utc)"
mkdir -p "$(dirname "$STATUS_FILE")"
cat > "$STATUS_FILE" <<EOF
{
  "generated_at": "$ts",
  "circuit_breaker": {
    "status": "$cb_status",
    "spend": {"weekly": $weekly, "cap": $cap, "remaining": $remaining, "pct": $pct},
    "depth": {"current": 0, "max": $MAX_DEPTH},
    "global_stop": $global_stop
  },
  "workers": [
    {
      "name": "Belial",
      "session": "$SESSION",
      "status": "$worker_status",
      "model": "claude-opus-4.8",
      "effort": "high",
      "project": "AdVanced OS",
      "directory": "~/AdVanced-OS",
      "last_phase": "idle"
    }
  ],
  "cron_jobs": [
    {"name": "Belial Watchdog", "schedule": "every 5m", "last_run": "$ts", "last_status": "ok"},
    {"name": "ObsoleteBot Watchdog", "schedule": "every 5m", "last_run": "$ts", "last_status": "ok"},
    {"name": "PR Pipeline", "schedule": "every 15m", "last_run": "$ts", "last_status": "ok"},
    {"name": "Guild Summary", "schedule": "0 13 * * 3", "last_run": "$ts", "last_status": "ok"},
    {"name": "System Health", "schedule": "*/2 * * * *", "last_run": "$ts", "last_status": "ok"}
  ]
}
EOF

echo "wrote $STATUS_FILE"
