#!/usr/bin/env bash
# compound-learning.sh — Phase 5d append-only, human-curated learning file.
#
# Usage:
#   compound-learning.sh init
#   compound-learning.sh add "learning text" [--tags "dispatch,qa"]
#   compound-learning.sh show
#   compound-learning.sh inject
#
# Hermes may append observations. Kevin remains the curator: this script never
# deduplicates, rewrites, promotes, or removes entries automatically.
set -euo pipefail

LEARNINGS_FILE="${HERMES_LEARNINGS_FILE:-$HOME/hermes-learnings.md}"
LOCK_FILE="${HERMES_LEARNINGS_LOCK:-$HOME/.hermes/hermes-learnings.lock}"

init_file() {
  mkdir -p "$(dirname "$LEARNINGS_FILE")" "$(dirname "$LOCK_FILE")"
  exec 9>"$LOCK_FILE"
  flock 9
  if [[ ! -f "$LEARNINGS_FILE" ]]; then
    umask 077
    {
      printf '# Hermes Compound Learnings\n\n'
      printf '> Machine-writeable, human-curated. Kevin decides what stays and what becomes a skill.\n\n'
      printf '## Active Learnings\n\n'
    } > "$LEARNINGS_FILE"
  fi
}

clean_line() {
  local value="${1:-}"
  value="${value//$'\n'/ }"
  value="${value//$'\r'/ }"
  printf '%s' "$value"
}

case "${1:-}" in
  init)
    init_file
    echo "$LEARNINGS_FILE"
    ;;

  add)
    [[ -n "${2:-}" ]] || {
      echo "usage: compound-learning.sh add \"learning text\" [--tags \"tag,tag\"]" >&2
      exit 2
    }
    text="$2"
    shift 2
    tags="general"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --tags) tags="${2:?--tags needs a value}"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    text="$(clean_line "$text")"
    tags="$(clean_line "$tags")"
    [[ -n "${text// /}" ]] || {
      echo "error: learning text cannot be empty" >&2
      exit 2
    }
    (( ${#text} <= 1000 )) || {
      echo "error: learning text exceeds 1000 characters" >&2
      exit 2
    }
    (( ${#tags} <= 120 )) || {
      echo "error: tags exceed 120 characters" >&2
      exit 2
    }
    init_file
    printf -- '- %s [%s] %s\n' "$(date -u +%Y-%m-%d)" "$tags" "$text" >> "$LEARNINGS_FILE"
    ;;

  show)
    init_file
    cat "$LEARNINGS_FILE"
    ;;

  inject)
    init_file
    # Keep task preambles bounded. The source file remains complete for Kevin.
    tail -c 12000 "$LEARNINGS_FILE"
    ;;

  -h|--help|help|"")
    sed -n '2,12p' "$0" | sed 's/^# \?//'
    ;;

  *)
    echo "error: unknown command '${1:-}'" >&2
    exit 2
    ;;
esac
