#!/usr/bin/env bash
# hermes-alert.sh — push a Discord notification via webhook. Standalone: callable
# from scripts, cron jobs, and the circuit breaker (works outside the dispatch cycle).
# No jq — python3 builds the JSON so titles/messages are safely escaped.
#
#   hermes-alert.sh send --level <info|warn|alert|critical> --title T --message M [--config P]
#
# Exit codes: 0 = sent (or rate-limited), 1 = config error (no webhook), 2 = delivery failed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/../config/circuit-breaker.yaml"
STATE_DIR="${HERMES_ALERT_STATE:-$HOME/.hermes/alerts}"
RATE_LIMIT_SECONDS=30   # Discord webhook courtesy: at most one alert per level per 30s

# read a flat key from the simple YAML (same convention as circuit-breaker.sh).
# `|| true` so an absent key doesn't fail the pipeline under `set -o pipefail`.
yaml_get() {
  local key="${1:-}" file="${2:-}"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
    echo "error: invalid configuration key" >&2
    return 1
  }
  { grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null || true; } | head -n1 \
    | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^\"//; s/\"$//"
}

# Webhook resolution order: env var > gitignored file > config value (empty in repo).
# The URL is sensitive, so it must NEVER live in the committed YAML.
resolve_webhook() {
  [[ -n "${HERMES_ALERT_WEBHOOK:-}" ]] && { printf '%s' "$HERMES_ALERT_WEBHOOK"; return; }
  local f="$HOME/.hermes/alert-webhook"
  [[ -s "$f" ]] && { head -n1 "$f"; return; }
  yaml_get webhook_url "$1"
}

color_for() {   # Discord embed colors (decimal)
  case "$1" in
    info)     echo 3447003  ;;  # blue
    warn)     echo 16776960 ;;  # yellow
    alert)    echo 15105570 ;;  # orange
    critical) echo 15158332 ;;  # red
    *)        echo 3447003  ;;
  esac
}

log_event() {   # best-effort audit trail; never fails the caller
  bash "$SCRIPT_DIR/agent-event.sh" log --correlation-id "alert:0" \
    --event alert --agent hermes-alert --detail "$1" 2>/dev/null || true
}

[[ "${1:-}" == "send" ]] || {
  echo "usage: hermes-alert.sh send --level <info|warn|alert|critical> --title T --message M [--config P]" >&2
  exit 1
}
shift

LEVEL="" TITLE="" MESSAGE="" CONFIG="$DEFAULT_CONFIG"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --level)   LEVEL="${2:?--level needs a value}";   shift 2 ;;
    --title)   TITLE="${2:?--title needs a value}";   shift 2 ;;
    --message) MESSAGE="${2:?--message needs a value}"; shift 2 ;;
    --config)  CONFIG="${2:?--config needs a value}"; shift 2 ;;
    *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
  esac
done
[[ -n "$LEVEL" && -n "$TITLE" && -n "$MESSAGE" ]] \
  || { echo "error: --level, --title, --message required" >&2; exit 1; }
case "$LEVEL" in info|warn|alert|critical) ;; *) echo "error: bad level '$LEVEL'" >&2; exit 1 ;; esac

mkdir -p "$STATE_DIR"

# --- per-level rate limit ---
rl="$STATE_DIR/ratelimit-$LEVEL"
if [[ -f "$rl" ]]; then
  now=$(date +%s); last=$(cat "$rl" 2>/dev/null || echo 0)
  if (( now - last < RATE_LIMIT_SECONDS )); then
    echo "rate-limited: $LEVEL alert suppressed (<${RATE_LIMIT_SECONDS}s since last)" >&2
    exit 0
  fi
fi

WEBHOOK="$(resolve_webhook "$CONFIG")"
if [[ -z "$WEBHOOK" ]]; then
  echo "error: no webhook configured — set HERMES_ALERT_WEBHOOK or write the URL to ~/.hermes/alert-webhook" >&2
  log_event "UNSENT[$LEVEL] $TITLE — no webhook configured"
  exit 1
fi

COLOR="$(color_for "$LEVEL")"
SOURCE="${HERMES_ALERT_SOURCE:-$(hostname -s 2>/dev/null || echo hermes)}"
payload="$(python3 -c '
import json, sys, datetime
level, title, message, color, source = sys.argv[1:6]
prefix = {"info": "", "warn": "⚠ ", "alert": "\U0001f7e0 ", "critical": "\U0001f534 "}.get(level, "")
embed = {
    "title": prefix + title,
    "description": message,
    "color": int(color),
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "footer": {"text": f"AdVanced OS · {source} · {level.upper()}"},
}
print(json.dumps({"embeds": [embed]}))' "$LEVEL" "$TITLE" "$MESSAGE" "$COLOR" "$SOURCE")"

code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' --data-raw "$payload" "$WEBHOOK" 2>/dev/null || echo 000)"

date +%s > "$rl"   # record attempt time (success or fail) to throttle a flapping webhook
if [[ "$code" =~ ^2 ]]; then
  log_event "SENT[$LEVEL] $TITLE"
  exit 0
fi
echo "error: Discord webhook returned HTTP $code" >&2
log_event "FAILED[$LEVEL] $TITLE — HTTP $code"
exit 2
