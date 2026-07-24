#!/usr/bin/env bash
# pipeline-verify.sh — validate a dev pipeline's artifacts end-to-end.
# Usage: pipeline-verify.sh <pipeline-uuid> [--strict]
# Exits 0 if all stages pass, 1 if any check fails.
# --strict mode also validates correlation ID chains and timing constraints.
set -euo pipefail

PIPE_DIR="${HERMES_PIPELINE_DIR:-$HOME/.hermes/dev-pipeline}"

# ── colours ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pass() { printf "  ${GREEN}PASS${NC}  %s\n" "$1"; }
fail() { printf "  ${RED}FAIL${NC}  %s — %s\n" "$1" "${2:-}" ; FAILURES=$((FAILURES + 1)); }
warn() { printf "  ${YELLOW}WARN${NC}  %s — %s\n" "$1" "${2:-}"; WARNINGS=$((WARNINGS + 1)); }
skip() { printf "  ${CYAN}SKIP${NC}  %s — %s\n" "$1" "$2"; }

# ── helpers ──────────────────────────────────────────────────────────────
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch()   { date -u -d "$1" +%s 2>/dev/null || echo 0; }
file_age() {
  local f="$1" now
  [[ -f "$f" ]] || { echo "MISSING"; return; }
  now=$(date +%s)
  local age=$(( now - $(date -r "$f" +%s) ))
  if (( age < 60 )); then echo "${age}s ago";
  elif (( age < 3600 )); then echo "$(( age / 60 ))m ago";
  else echo "$(( age / 3600 ))h ago"; fi
}
cid_depth() { echo "$1" | sed 's/.*://' ; }

# ── stage validators ─────────────────────────────────────────────────────

verify_skeleton() {
  local d="$1" name
  name=$(cat "$d/name" 2>/dev/null || echo "(unnamed)")
  printf "\n${CYAN}═══ Pipeline: %s${NC}\n" "$name"
  printf "${CYAN}    UUID: %s${NC}\n" "$uuid"

  printf "\n${CYAN}▸ Skeleton checks${NC}\n"
  [[ -f "$d/state" ]]      && pass "state file exists ($(cat "$d/state"))"          || fail "state file" "missing"
  [[ -f "$d/name" ]]       && pass "name file exists ($(cat "$d/name"))"            || fail "name file" "missing"
  [[ -f "$d/task.md" ]]    && pass "task.md exists ($(wc -c < "$d/task.md") bytes)" || fail "task.md" "missing"
  [[ -f "$d/created_at" ]] && pass "created_at exists ($(cat "$d/created_at"))"      || fail "created_at" "missing"
  [[ -f "$d/root_cid" ]]   && pass "root_cid exists ($(cat "$d/root_cid"))"          || fail "root_cid" "missing"

  local state
  state=$(cat "$d/state" 2>/dev/null || echo "UNKNOWN")
  case "$state" in
    researching|scaffolding|building|done)
      pass "state ($state) is a recognised pipeline stage" ;;
    failed)
      warn "state is 'failed' — pipeline auto-advance halted" ;;
    *)
      warn "state is '$state' — unrecognised" ;;
  esac
}

verify_stage() {
  local d="$1" stage="$2" label="$3" agent_name="$4" required="$5"
  local sub="$d/$stage"

  printf "\n${CYAN}▸ Stage: %s ($label)${NC}\n" "$stage"

  if [[ ! -d "$sub" ]]; then
    if [[ "$required" == true ]]; then fail "directory $sub" "missing"; else skip "directory $sub" "not yet created (pipeline hasn't reached this stage)"; fi
    return
  fi

  # Core artifacts
  [[ -f "$sub/sent_at" ]]      && pass "sent_at exists ($(cat "$sub/sent_at"))"       || fail "sent_at" "missing — dispatch never delivered"
  [[ -f "$sub/agent" ]]        && pass "agent file ($(cat "$sub/agent"))"              || fail "agent file" "missing"
  [[ -f "$sub/dispatch_cid" ]] && pass "dispatch_cid exists ($(cat "$sub/dispatch_cid"))" || fail "dispatch_cid" "missing"

  # Output capture
  if [[ -f "$sub/output.md" ]]; then
    local sz; sz=$(wc -c < "$sub/output.md")
    if (( sz > 100 )); then
      pass "output.md captured ($sz bytes)"
    else
      warn "output.md is too small ($sz bytes) — may be an empty capture"
    fi
  else
    if [[ "$required" == true ]]; then
      fail "output.md" "not captured yet — agent may still be working or hung"
    else
      warn "output.md" "not captured yet — agent still working (this is expected for active stages)"
    fi
  fi

  [[ -f "$sub/completed_at" ]] && pass "completed_at captured ($(cat "$sub/completed_at"))" || warn "completed_at" "not written yet"

  # Agent name matches expected
  if [[ -f "$sub/agent" ]]; then
    local actual; actual=$(cat "$sub/agent")
    if [[ "$actual" == "$agent_name" ]]; then
      pass "agent matches expected ($agent_name)"
    else
      warn "agent is '$actual', expected '$agent_name'"
    fi
  fi

  # Strict: correlation ID depth check
  if [[ "$STRICT" == true && -f "$sub/dispatch_cid" ]]; then
    local cid; cid=$(cat "$sub/dispatch_cid")
    local depth; depth=$(cid_depth "$cid")
    case "$stage" in
      research) (( depth == 0 )) && pass "CID stage correct (0 for research)" || warn "CID stage is $depth, expected 0" ;;
      scaffold) (( depth == 1 )) && pass "CID stage correct (1 for scaffold)" || warn "CID stage is $depth, expected 1" ;;
      build)    (( depth == 2 )) && pass "CID stage correct (2 for build)"    || warn "CID stage is $depth, expected 2" ;;
    esac
  fi

  # Strict: timing guard (sent_at → completed_at gap)
  if [[ "$STRICT" == true && -f "$sub/sent_at" && -f "$sub/completed_at" ]]; then
    local sent completed gap
    sent=$(cat "$sub/sent_at"); completed=$(cat "$sub/completed_at")
    gap=$(( $(epoch "$completed") - $(epoch "$sent") ))
    if (( gap >= 30 )); then
      pass "timing: ${gap}s between dispatch and capture (>= 30s MIN_WORK guard)"
    else
      warn "timing: ${gap}s between dispatch and capture — MIN_WORK is 30s"
    fi
  fi
}

verify_report() {
  local d="$1"
  printf "\n${CYAN}▸ Final report${NC}\n"

  if [[ -f "$d/report.md" ]]; then
    local sz; sz=$(wc -c < "$d/report.md")
    pass "report.md generated ($sz bytes)"
  else
    local state; state=$(cat "$d/state" 2>/dev/null || echo "")
    if [[ "$state" == "done" ]]; then
      fail "report.md" "missing but state is 'done' — generate_report didn't fire"
    else
      skip "report.md" "pipeline not yet at 'done' state"
    fi
  fi
}

verify_artifact_integrity() {
  local d="$1"
  printf "\n${CYAN}▸ Artifact integrity${NC}\n"

  # Check for empty files that should have content
  for f in state name task.md created_at root_cid; do
    [[ -f "$d/$f" ]] || continue
    local sz; sz=$(wc -c < "$d/$f")
    if (( sz < 2 )); then
      warn "$f is suspiciously small ($sz byte(s))"
    else
      pass "$f has content ($sz bytes)"
    fi
  done

  # Check directory structure
  for sub in research scaffold build; do
    if [[ -d "$d/$sub" ]]; then
      pass "directory $sub/ exists"
    else
      warn "directory $sub/ does not exist"
    fi
  done
}

# ── main ─────────────────────────────────────────────────────────────────

uuid="${1:-}"; STRICT=false
[[ "${2:-}" == "--strict" ]] && STRICT=true

if [[ -z "$uuid" ]]; then
  echo "usage: pipeline-verify.sh <pipeline-uuid> [--strict]" >&2
  echo "  Validates all pipeline stages and artifacts." >&2
  echo "  --strict: also validate CID depth chains and timing constraints." >&2
  echo "" >&2
  echo "Available pipelines:" >&2
  for d in "$PIPE_DIR"/*/; do
    [[ -f "$d/state" ]] || continue
    d="${d%/}"
    printf "  %-40s state=%-12s name=%s\n" "$(basename "$d")" "$(cat "$d/state")" "$(cat "$d/name" 2>/dev/null || echo '?')" >&2
  done
  exit 1
fi

dir="$PIPE_DIR/$uuid"

if [[ ! -d "$dir" ]]; then
  echo "error: pipeline directory not found: $dir" >&2
  exit 1
fi

FAILURES=0; WARNINGS=0

printf "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}\n"
printf "${CYAN}║  Pipeline Verification Report                               ║${NC}\n"
printf "${CYAN}║  Run at: %-50s ║${NC}\n" "$(now_iso)"
printf "${CYAN}║  Mode:   %-50s ║${NC}\n" "$( [[ "$STRICT" == true ]] && echo 'STRICT' || echo 'standard' )"
printf "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}\n"

verify_skeleton "$dir"
verify_artifact_integrity "$dir"

# Determine expected completion based on current state
state=$(cat "$dir/state" 2>/dev/null || echo "UNKNOWN")

verify_stage "$dir" "research"  "Research (Ezekiel)"     "ezekiel"       true

case "$state" in
  researching)
    verify_stage "$dir" "scaffold" "Scaffold (Sammael)"   "sammael"       false
    verify_stage "$dir" "build"    "Build (Belial)"       "claude-belial" false
    ;;
  scaffolding)
    verify_stage "$dir" "scaffold" "Scaffold (Sammael)"   "sammael"       true
    verify_stage "$dir" "build"    "Build (Belial)"       "claude-belial" false
    ;;
  building)
    verify_stage "$dir" "scaffold" "Scaffold (Sammael)"   "sammael"       true
    verify_stage "$dir" "build"    "Build (Belial)"       "claude-belial" true
    ;;
  done)
    verify_stage "$dir" "scaffold" "Scaffold (Sammael)"   "sammael"       true
    verify_stage "$dir" "build"    "Build (Belial)"       "claude-belial" true
    verify_report "$dir"
    ;;
  *)
    verify_stage "$dir" "scaffold" "Scaffold (Sammael)"   "sammael"       false
    verify_stage "$dir" "build"    "Build (Belial)"       "claude-belial" false
    ;;
esac

# Summary
printf "\n${CYAN}══════════════════════════════════════════════════════════════${NC}\n"
if (( FAILURES == 0 && WARNINGS == 0 )); then
  printf "${GREEN}Result: ALL CHECKS PASSED${NC}\n"
elif (( FAILURES == 0 )); then
  printf "${YELLOW}Result: PASSED with ${WARNINGS} warning(s)${NC}\n"
else
  printf "${RED}Result: ${FAILURES} FAILURE(S), ${WARNINGS} warning(s)${NC}\n"
fi
printf "${CYAN}══════════════════════════════════════════════════════════════${NC}\n"

exit $(( FAILURES > 0 ? 1 : 0 ))
