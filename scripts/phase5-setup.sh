#!/usr/bin/env bash
# phase5-setup.sh — install and inspect the Phase 5 local runtime wiring.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HERMES_SCRIPT_DIR="${HERMES_SCRIPT_DIR:-$HOME/.hermes/scripts}"
HERMES_CONFIG_DIR="${HERMES_CONFIG_DIR:-$HOME/.hermes/config}"

scripts=(
  agent-event
  circuit-breaker
  compound-learning
  correlation-id
  dispatch-lane
  global-stop
  hermes-notify
  hermes-request
  qa-gate
  ticket-scan
)

install_phase5() {
  mkdir -p "$HERMES_SCRIPT_DIR" "$HERMES_CONFIG_DIR"
  for name in "${scripts[@]}"; do
    target="$HERMES_SCRIPT_DIR/$name.sh"
    if [[ -e "$target" && ! -L "$target" ]]; then
      echo "error: refusing to replace non-symlink runtime file: $target" >&2
      return 1
    fi
    ln -sfn "$REPO_ROOT/scripts/$name.sh" "$target"
  done
  config_target="$HERMES_CONFIG_DIR/circuit-breaker.yaml"
  if [[ -e "$config_target" && ! -L "$config_target" ]]; then
    echo "error: refusing to replace non-symlink runtime config: $config_target" >&2
    return 1
  fi
  ln -sfn "$REPO_ROOT/config/circuit-breaker.yaml" "$config_target"
  bash "$SCRIPT_DIR/compound-learning.sh" init >/dev/null
  bash "$SCRIPT_DIR/ticket-scan.sh" init >/dev/null
  echo "Phase 5 runtime installed."
  echo "Ticket intake: ${HERMES_TICKET_DIR:-$HOME/vaults/kevin/tickets}"
  echo "Learnings: ${HERMES_LEARNINGS_FILE:-$HOME/hermes-learnings.md}"
  echo "The existing Dispatch Queue Consumer poll owns ticket scanning and QA completions."
}

status_phase5() {
  failed=0
  for name in "${scripts[@]}"; do
    target="$HERMES_SCRIPT_DIR/$name.sh"
    if [[ -L "$target" && "$(readlink -f "$target")" == "$REPO_ROOT/scripts/$name.sh" ]]; then
      printf 'ok      %s\n' "$target"
    else
      printf 'missing %s\n' "$target"
      failed=1
    fi
  done
  [[ -f "${HERMES_LEARNINGS_FILE:-$HOME/hermes-learnings.md}" ]] \
    && echo "ok      compound learning file" \
    || { echo "missing compound learning file"; failed=1; }
  [[ -d "${HERMES_TICKET_DIR:-$HOME/vaults/kevin/tickets}" ]] \
    && echo "ok      ticket directory" \
    || { echo "missing ticket directory"; failed=1; }
  if curl --max-time 2 --fail --silent \
    "http://127.0.0.1:${MISSION_CONTROL_PORT:-4001}/api/phase5" >/dev/null; then
    echo "ok      Mission Control Phase 5 API"
  else
    echo "missing Mission Control Phase 5 API"
    failed=1
  fi
  return "$failed"
}

case "${1:-}" in
  install) install_phase5 ;;
  status) status_phase5 ;;
  -h|--help|help|"")
    echo "usage: phase5-setup.sh install|status"
    ;;
  *)
    echo "error: unknown command '$1'" >&2
    exit 2
    ;;
esac
