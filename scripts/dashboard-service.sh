#!/usr/bin/env bash
# dashboard-service.sh — install and operate Mission Control as a system service.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT_NAME="advanced-os-dashboard@.service"
SERVICE_NAME="advanced-os-dashboard@$(id -un).service"
UNIT_SOURCE="$REPO_ROOT/config/systemd/$UNIT_NAME"
UNIT_TARGET="/etc/systemd/system/$UNIT_NAME"
PORT="4001"

run_privileged() {
  if (( EUID == 0 )); then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "error: this action requires root privileges and sudo is unavailable" >&2
    return 126
  fi
}

usage() {
  cat <<EOF
dashboard-service.sh — Mission Control service lifecycle

Usage:
  dashboard-service.sh install   Install, enable, and start the systemd service
  dashboard-service.sh restart   Restart after updating the checkout
  dashboard-service.sh status    Show service and API health

Service: $SERVICE_NAME
Health:  http://127.0.0.1:$PORT/api/health
EOF
}

wait_for_health() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if systemctl is-active --quiet "$SERVICE_NAME" \
      && curl --max-time 1 --fail --silent "http://127.0.0.1:$PORT/api/health" >/dev/null; then
      sleep 0.5
      if systemctl is-active --quiet "$SERVICE_NAME" \
        && curl --max-time 1 --fail --silent "http://127.0.0.1:$PORT/api/health" >/dev/null; then
        return 0
      fi
    fi
    sleep 0.5
  done
  echo "error: Mission Control did not become healthy on port $PORT" >&2
  return 1
}

case "${1:-}" in
  install)
    [[ -f "$UNIT_SOURCE" ]] || {
      echo "error: service template not found: $UNIT_SOURCE" >&2
      exit 1
    }
    if ! systemctl is-active --quiet "$SERVICE_NAME" \
      && curl --max-time 1 --fail --silent "http://127.0.0.1:$PORT/api/health" >/dev/null; then
      echo "error: port $PORT is already served outside $SERVICE_NAME; stop the unmanaged dashboard before installing" >&2
      exit 1
    fi
    run_privileged install -m 0644 "$UNIT_SOURCE" "$UNIT_TARGET"
    run_privileged systemctl daemon-reload
    run_privileged systemctl enable "$SERVICE_NAME"
    run_privileged systemctl restart "$SERVICE_NAME"
    wait_for_health
    echo "Mission Control installed and healthy: $SERVICE_NAME"
    ;;
  restart)
    run_privileged systemctl restart "$SERVICE_NAME"
    wait_for_health
    echo "Mission Control restarted and healthy: $SERVICE_NAME"
    ;;
  status)
    systemctl --no-pager --full status "$SERVICE_NAME"
    curl --max-time 2 --fail --silent --show-error \
      "http://127.0.0.1:$PORT/api/health"
    echo
    ;;
  -h|--help|help|"")
    usage
    ;;
  *)
    echo "error: unknown command '$1'" >&2
    usage >&2
    exit 1
    ;;
esac
