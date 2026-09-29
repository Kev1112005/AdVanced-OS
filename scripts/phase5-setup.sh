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
  local name source target config_source config_target
  config_source="$REPO_ROOT/config/circuit-breaker.yaml"
  config_target="$HERMES_CONFIG_DIR/circuit-breaker.yaml"

  # Validate the complete source/target set before creating a directory or
  # replacing a link. A late conflict must leave the runtime tree untouched.
  for name in "${scripts[@]}"; do
    source="$REPO_ROOT/scripts/$name.sh"
    target="$HERMES_SCRIPT_DIR/$name.sh"
    if [[ ! -f "$source" ]]; then
      echo "error: Phase 5 source is missing: $source" >&2
      return 1
    fi
    if [[ (-e "$target" || -L "$target") && ! -L "$target" ]]; then
      echo "error: refusing to replace non-symlink runtime file: $target" >&2
      return 1
    fi
  done
  if [[ ! -f "$config_source" ]]; then
    echo "error: Phase 5 config source is missing: $config_source" >&2
    return 1
  fi
  if [[ (-e "$config_target" || -L "$config_target") && ! -L "$config_target" ]]; then
    echo "error: refusing to replace non-symlink runtime config: $config_target" >&2
    return 1
  fi

  mkdir -p "$HERMES_SCRIPT_DIR" "$HERMES_CONFIG_DIR"
  for name in "${scripts[@]}"; do
    target="$HERMES_SCRIPT_DIR/$name.sh"
    ln -sfn "$REPO_ROOT/scripts/$name.sh" "$target"
  done
  ln -sfn "$config_source" "$config_target"
  bash "$SCRIPT_DIR/compound-learning.sh" init >/dev/null
  bash "$SCRIPT_DIR/ticket-scan.sh" init >/dev/null
  echo "Phase 5 runtime installed."
  echo "Ticket intake: ${HERMES_TICKET_DIR:-$HOME/vaults/kevin/tickets}"
  echo "Learnings: ${HERMES_LEARNINGS_FILE:-$HOME/hermes-learnings.md}"
  echo "The existing Dispatch Queue Consumer poll owns ticket scanning and QA completions."
}

status_phase5() {
  local failed=0 name target config_target
  for name in "${scripts[@]}"; do
    target="$HERMES_SCRIPT_DIR/$name.sh"
    if [[ -L "$target" && "$(readlink -f "$target")" == "$REPO_ROOT/scripts/$name.sh" ]]; then
      printf 'ok      %s\n' "$target"
    else
      printf 'missing %s\n' "$target"
      failed=1
    fi
  done
  config_target="$HERMES_CONFIG_DIR/circuit-breaker.yaml"
  if [[ -L "$config_target" \
    && "$(readlink -f "$config_target")" == "$REPO_ROOT/config/circuit-breaker.yaml" ]]; then
    printf 'ok      %s\n' "$config_target"
  else
    printf 'missing %s\n' "$config_target"
    failed=1
  fi
  if [[ -f "${HERMES_LEARNINGS_FILE:-$HOME/hermes-learnings.md}" ]]; then
    echo "ok      compound learning file"
  else
    echo "missing compound learning file"
    failed=1
  fi
  if [[ -d "${HERMES_TICKET_DIR:-$HOME/vaults/kevin/tickets}" ]]; then
    echo "ok      ticket directory"
  else
    echo "missing ticket directory"
    failed=1
  fi
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
