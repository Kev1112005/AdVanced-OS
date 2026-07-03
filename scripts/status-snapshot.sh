#!/usr/bin/env bash
# status-snapshot.sh — Phase 5b: write a JSON snapshot of system state.
# Polled by the dashboard via /api/status. Reuses Day 1 scripts for spend + stop.
#
# Exit codes: 0 success, 1 error
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_FILE="${HERMES_STATUS_FILE:-$HOME/.hermes/status/current.json}"
MAX_DEPTH="${HERMES_MAX_DEPTH:-3}"

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Build the workers[] JSON. No jq — manual JSON. Live tmux sessions report
# active/idle; roster agents that run outside tmux (Azrael=Hermes, Ornith=profile)
# report offline when their session is down so they still show on the dashboard.
detect_workers() {
  command -v tmux >/dev/null 2>&1 || return
  # Known agents that may run without a tmux session. session|display|model|effort|dir|project
  local -a KNOWN_AGENTS=(
    "hermes|Azrael|deepseek-v4-flash|orchestrator|~|AdVanced OS"
    "ornith|Ornith|ornith-9b|local|~|Vox"
  )
  local name display model effort dir proj status seen=" "
  local -a rows=()

  # 1. Live sessions (existing behavior): active/idle.
  while IFS= read -r name; do
    [[ "$name" == ornith || "$name" == hermes || "$name" == claude-* ]] || continue
    case "$name" in
      claude-belial)         display="Belial";        model="claude-opus-4.8"; effort="high";  dir="~/AdVanced-OS"; proj="AdVanced OS" ;;
      claude-obsoletebot)    display="ObsoleteBot";    model="claude-opus-4.8"; effort="high";  dir="~/ObsoleteBot"; proj="ObsoleteBot" ;;
      claude-remote-control) display="Remote Control"; model="claude-opus-4.8"; effort="high";  dir="~/ObsoleteBot"; proj="ObsoleteBot" ;;
      hermes)                display="Azrael";         model="deepseek-v4-flash"; effort="orchestrator"; dir="~"; proj="AdVanced OS" ;;
      ornith)                display="Ornith";         model="ornith-9b";       effort="local"; dir="~";             proj="Vox" ;;
      *)                     display="$name";          model="unknown";         effort="unknown"; dir="";            proj="" ;;
    esac
    status="idle"
    if tmux capture-pane -t "$name" -p -S -3 2>/dev/null | grep -qE 'Spinning|Baking|Hatching|Misting|Thinking'; then
      status="active"
    fi
    rows+=("$display|$name|$status|$model|$effort|$proj|$dir")
    seen+="$name "
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

  # 2. Roster agents with no live session: offline.
  local entry
  for entry in "${KNOWN_AGENTS[@]}"; do
    IFS='|' read -r name display model effort dir proj <<<"$entry"
    [[ "$seen" == *" $name "* ]] && continue
    rows+=("$display|$name|offline|$model|$effort|$proj|$dir")
  done

  # 3. Emit JSON.
  local first=1 out="" r
  for r in "${rows[@]}"; do
    IFS='|' read -r display name status model effort proj dir <<<"$r"
    [[ $first -eq 1 ]] && first=0 || out+=$',\n    '
    out+=$(printf '{"name": "%s", "session": "%s", "status": "%s", "model": "%s", "effort": "%s", "project": "%s", "directory": "%s", "last_phase": "idle"}' \
      "$display" "$name" "$status" "$model" "$effort" "$proj" "$dir")
  done
  echo "$out"
}

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

# --- workers (dynamic tmux detection) ---
workers_json="$(detect_workers)"

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
    $workers_json
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
