#!/usr/bin/env bash
# test_branch_sweep.sh — exercise branch-sweep.sh's idle ladder against a scratch repo.
# The one check that fails if the age thresholds, tier classification, or the
# dry-run guarantee break. Run: bash tests/test_branch_sweep.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$SCRIPT_DIR/../scripts/branch-sweep.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

ago() { date -u -d "$1 days ago" +%Y-%m-%dT%H:%M:%SZ; }

git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo"
cd "$TMP/repo"
git symbolic-ref HEAD refs/heads/main
echo base > README.md && git add -A
GIT_AUTHOR_DATE="$(ago 60)" GIT_COMMITTER_DATE="$(ago 60)" git commit -qm base
git push -q origin main

# One branch per rung. commit date == idle age (no worktrees in this fixture).
branch() {  # $1=name $2=days-ago $3=file
  git checkout -q -b "$1" main
  mkdir -p "$(dirname "$3")" && echo change > "$3" && git add -A
  GIT_AUTHOR_DATE="$(ago "$2")" GIT_COMMITTER_DATE="$(ago "$2")" git commit -qm "work on $1"
  git checkout -q main
}
branch idle-2d 2 src/a.txt
branch idle-8d 8 src/b.txt
branch idle-15d 15 src/c.txt
branch idle-30d 30 src/d.txt
branch tier2-5d 5 api/prisma/migrations/001/migration.sql
branch tier0-5d 5 docs/thing.md
git fetch -q origin

out="$(HERMES_SWEEP_LOG="$TMP/sweep.log" HERMES_STOP_FILE="$TMP/no-stop" \
  bash "$SWEEP" --dry-run "$TMP/repo" 2>/dev/null)"

fail=0
has() { grep -qF "$1" <<< "$out" || { echo "MISSING: $1"; fail=1; }; }
hasnt() { grep -qF "$1" <<< "$out" && { echo "UNEXPECTED: $1"; fail=1; }; return 0; }

has 'idle-2d idle 2d'
has 'idle-8d idle 1wk, no PR'
has 'would shelve'
has 'idle-15d'
has 'MANUAL'
has 'idle-30d idle 4wk, unique content'
has 'Tier 2 branch'
has 'tier2-5d'
has 'tier0-5d'

# The dry-run guarantee: never announce a completed deletion or merge.
hasnt 'deleted verified-merged'
hasnt 'auto-merged+deployed'
hasnt 'shelved '

# main is never a subject, and nothing actually mutated.
hasnt ' main '
[[ "$(git for-each-ref --format='%(refname:short)' refs/heads | wc -l)" == 7 ]] \
  || { echo "MUTATION: branches were deleted in dry-run"; fail=1; }

# Global stop silences the sweep entirely.
: > "$TMP/stop"
stopped="$(HERMES_SWEEP_LOG="$TMP/sweep.log" HERMES_STOP_FILE="$TMP/stop" \
  bash "$SWEEP" --dry-run "$TMP/repo" 2>/dev/null)"
[[ -z "$stopped" ]] || { echo "UNEXPECTED: output while global stop engaged"; fail=1; }

if (( fail )); then
  echo "--- actual output ---"; echo "$out"
  echo "FAIL"; exit 1
fi
echo "PASS"
