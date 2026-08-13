#!/usr/bin/env bash
# branch-sweep.sh — daily idle-branch sweep (Decision 010, tiered autonomy).
#
# Watchdog pattern: SILENT when there is nothing to report. Every line printed is a
# message to Kevin — either "I did this" or "you decide this".
#
#   branch-sweep.sh [--dry-run] [repo ...]
#
# Rule ladder per branch (first match wins), by idle age:
#   >= 4 weeks  content-verified-in-main -> delete branch+worktree, else MANUAL notice
#   >= 2 weeks  no open PR -> shelve (GitHub issue + remove worktree, keep branch)
#   >= 1 week   no open PR -> ping
#   >= 3 days   Tier 0/1 -> merge + deploy; Tier 2 -> defer to docket
#   >= 2 days   ping
#
# Env: HERMES_SWEEP_REPOS (space-separated), HERMES_SWEEP_LOG, HERMES_SWEEP_CI_WAIT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LOG_FILE="${HERMES_SWEEP_LOG:-$HOME/.hermes/logs/branch-sweep.log}"
CI_WAIT="${HERMES_SWEEP_CI_WAIT:-900}"
DEFAULT_REPOS="$HOME/ObsoleteBot $HOME/AdVanced-OS"

DAY=86400
DRY_RUN=0
ACTION_FAILED=0  # set by run_action when a mutation fails; reset per action group

# Tier 2 path patterns — a branch touching any of these never auto-merges.
TIER2_RE='(^|/)(api/)?prisma/|migration|auth|docker-compose\.prod\.yml|\.env|notify|ping|announce'

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG_FILE"
}

# say: message Kevin AND log it. Nothing else writes to stdout.
say() {
  local prefix=""
  (( DRY_RUN )) && prefix="[dry-run] "
  printf '%s%s\n' "$prefix" "$*"
  log "$prefix$*"
}

# past: verb for an action message — "would delete" under --dry-run, "deleted" otherwise.
past() {  # $1=dry wording $2=real wording
  (( DRY_RUN )) && { printf '%s' "$1"; return; }
  printf '%s' "$2"
}

# run_action: perform a mutation, or describe it under --dry-run.
#
# A failed action must never abort the pass. On the 2026-08-13 run a single
# rejected `gh pr create` (local-only branch) killed the whole sweep under
# `set -e`, so every branch after it went unprocessed and the cron reported
# failure. This reports the failure and returns 0 so the loop moves on; callers
# that need the outcome either re-query state (open_pr) or check ACTION_FAILED.
run_action() {  # $1=action label, e.g. "pr create org/repo:branch"; $2...=command
  local label="$1"; shift
  if (( DRY_RUN )); then
    log "[dry-run] would run: $*"
    return 0
  fi
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if (( rc )); then
    ACTION_FAILED=1
    say "FAILED: $label: $(tr '\n' ' ' <<< "$out" | cut -c1-300)"
  fi
  return 0
}

# True when the branch exists on origin. gh pr create needs it there.
on_origin() {  # $1=repo $2=branch
  git -C "$1" ls-remote --heads --exit-code origin "$2" >/dev/null 2>&1
}

while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown flag $1" >&2; exit 1 ;;
    *) break ;;
  esac
done

# Global stop wins over every tier. Silent exit — a stopped system says nothing.
if bash "$SCRIPT_DIR/global-stop.sh" check >/dev/null 2>&1; then
  log "global stop engaged — sweep skipped"
  exit 0
fi

read -r -a REPOS <<< "${*:-${HERMES_SWEEP_REPOS:-$DEFAULT_REPOS}}"

now="$(date +%s)"
days() { echo $(( (now - $1) / DAY )); }

# Branch checked out in a linked worktree -> its path, else empty.
worktree_of() {  # $1=repo $2=branch
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk -v want="refs/heads/$2" '
        /^worktree /  { path = substr($0, 10) }
        /^branch /    { if (substr($0, 8) == want) { print path; exit } }'
}

# Tier 2 if any changed file since the merge-base matches a risky path pattern.
tier2() {  # $1=repo $2=branch
  local base
  base="$(git -C "$1" merge-base "$2" origin/main 2>/dev/null)" || return 1
  git -C "$1" diff --name-only "$base" "$2" 2>/dev/null | grep -Eqi "$TIER2_RE"
}

# True when a branch adds no new content to main.
#
# Ancestry cannot answer this: a squash-merge rewrites the branch's commits into
# one new commit, so the originals stay unreachable from main and
# `rev-list origin/main..$branch` reports them as unique forever. That is how
# ObsoleteBot #499/#503 got duplicate PRs opened for work merged days earlier as
# #483/#493 — both then failed to merge on conflicts with the drifted main.
#
# git cherry compares patch-ids instead, marking a commit '-' when an equivalent
# diff is already upstream and '+' when it is genuinely new. Checked against the
# remote ref too when one exists, because `gh pr create --head` proposes the
# remote branch, not the local one, and the two can diverge. Merged means neither
# side has unique content — on any doubt (missing ref, failed git call) we report
# not-merged, so the caller pings instead of deleting.
already_merged() {  # $1=repo $2=branch
  local ref out checked=0
  for ref in "$2" "refs/remotes/origin/$2"; do
    git -C "$1" rev-parse --verify --quiet "$ref" >/dev/null || continue
    out="$(git -C "$1" cherry origin/main "$ref" 2>/dev/null)" || return 1
    if grep -q '^+' <<< "$out"; then return 1; fi
    checked=$(( checked + 1 ))
  done
  (( checked > 0 ))  # a branch we could not resolve is never "verified merged"
}

open_pr() {  # $1=repo $2=branch -> PR number on stdout, empty if none
  gh pr list --repo "$1" --head "$2" --state open --json number \
    --jq '.[0].number // empty' 2>/dev/null || true
}

pr_mergeable() {  # $1=repo $2=pr — CI green and no requested changes
  local json review
  json="$(gh pr view "$2" --repo "$1" --json reviewDecision,mergeable 2>/dev/null)" || return 1
  [[ "$(jq -r '.mergeable' <<< "$json")" == "MERGEABLE" ]] || return 1
  review="$(jq -r '.reviewDecision // ""' <<< "$json")"
  [[ "$review" != "CHANGES_REQUESTED" ]] || return 1
  gh pr checks "$2" --repo "$1" >/dev/null 2>&1
}

merge_and_deploy() {  # $1=repo_dir $2=slug $3=pr $4=branch
  ACTION_FAILED=0
  run_action "pr merge $2#$3" gh pr merge "$3" --repo "$2" --squash --delete-branch
  if (( ACTION_FAILED )); then
    say "branch $2:$4 left open — merge failed (see log)"
    return 0
  fi
  # ponytail: deploy is the repo's own pipeline if it has one; docs-only repos have none.
  if [[ -x "$1/scripts/auto-pr-pipeline.sh" ]]; then
    run_action "deploy $2#$3" bash "$1/scripts/auto-pr-pipeline.sh" deploy "$3"
  fi
  if (( ACTION_FAILED )); then
    say "MANUAL: $2#$3 merged but deploy failed — prod may be behind main"
    return 0
  fi
  say "$(past 'would auto-merge+deploy' 'auto-merged+deployed') $2#$3 ($4) (day-3 rule)"
}

sweep_repo() {
  local repo="$1" slug root_branch branch head_ts age wt pr base_ts
  [[ -d "$repo/.git" || -f "$repo/.git" ]] || return 0
  slug="$(git -C "$repo" remote get-url origin 2>/dev/null \
    | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#')" || return 0
  [[ -n "$slug" ]] || return 0
  git -C "$repo" fetch origin --quiet --prune 2>/dev/null || true

  # Never touch the branch the deploy checkout itself sits on.
  root_branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

  while read -r branch; do
    [[ "$branch" == "main" || "$branch" == "master" ]] && continue
    [[ -n "$root_branch" && "$branch" == "$root_branch" ]] && continue

    base_ts="$(git -C "$repo" log -1 --format=%ct "$branch" 2>/dev/null || echo 0)"
    [[ "$base_ts" =~ ^[0-9]+$ ]] || continue
    head_ts="$base_ts"
    wt="$(worktree_of "$repo" "$branch")"
    if [[ -n "$wt" && -d "$wt" ]]; then
      local wt_ts
      wt_ts="$(stat -c %Y "$wt" 2>/dev/null || echo 0)"
      (( wt_ts > head_ts )) && head_ts="$wt_ts"
    fi
    age="$(days "$head_ts")"

    if (( age >= 28 )); then
      # Ancestry is a lie after a squash-merge: ask what content is unique, not what merged.
      if already_merged "$repo" "$branch"; then
        [[ -n "$wt" ]] && run_action "worktree remove $slug:$branch" git -C "$repo" worktree remove --force "$wt"
        run_action "branch delete $slug:$branch" git -C "$repo" branch -D "$branch"
        say "$(past 'would delete' 'deleted') verified-merged branch $slug:$branch (idle ${age}d)"
      else
        say "MANUAL: branch $slug:$branch idle 4wk, unique content"
      fi
      continue
    fi

    pr="$(open_pr "$slug" "$branch")"

    if (( age >= 14 )) && [[ -z "$pr" ]]; then
      run_action "issue create $slug:$branch" gh issue create --repo "$slug" --title "shelved: $branch" \
        --body "$(# shellcheck disable=SC2016  # printf format string, not an expansion
          printf 'Branch `%s` shelved by branch-sweep after %d days idle with no open PR.\n\nLast commit:\n\n```\n%s\n```\n\nWorktree removed; branch kept. Reopen by checking the branch out again.\n' \
          "$branch" "$age" "$(git -C "$repo" log -1 --format='%h %ad %an%n%n%s%n%n%b' --date=short "$branch" 2>/dev/null)")"
      [[ -n "$wt" ]] && run_action "worktree remove $slug:$branch" git -C "$repo" worktree remove --force "$wt"
      say "$(past 'would shelve' 'shelved') $slug:$branch (idle ${age}d, no PR) — issue filed, worktree removed, branch kept"
      continue
    fi

    if (( age >= 7 )) && [[ -z "$pr" ]]; then
      say "branch $slug:$branch idle 1wk, no PR — prune or PR?"
      continue
    fi

    if (( age >= 3 )); then
      # A branch whose content is already in main is merged, however it got there.
      # Don't open a PR for it: gh pr create --fill fails with "could not find any
      # commits" when the branch is strictly empty, and a squash-merged branch
      # produces a duplicate PR that then conflicts against the drifted main.
      # BUT: never delete a worktree with uncommitted changes — that's live work.
      if already_merged "$repo" "$branch"; then
        if [[ -n "$wt" ]] && ! git -C "$wt" diff --quiet 2>/dev/null; then
          say "MANUAL: branch $slug:$branch appears merged but worktree has uncommitted changes — do not touch"
          continue
        fi
        [[ -n "$wt" ]] && run_action "worktree remove $slug:$branch" git -C "$repo" worktree remove --force "$wt"
        run_action "branch delete $slug:$branch" git -C "$repo" branch -D "$branch"
        say "$(past 'would delete' 'deleted') verified-merged branch $slug:$branch (idle ${age}d)"
        continue
      fi
      if tier2 "$repo" "$branch"; then
        say "Tier 2 branch $slug:$branch idle 3d — deferred to docket"
        continue
      fi
      if [[ -z "$pr" ]]; then
        # gh pr create needs the head branch on origin. A local-only branch made
        # GitHub reject the call outright ("Head sha can't be blank ... Head ref
        # must be a branch"), which is what aborted the 2026-08-13 sweep.
        if ! on_origin "$repo" "$branch"; then
          say "$(past 'would push' 'pushed') unpushed branch $slug:$branch to origin (day-3 rule)"
          run_action "push $slug:$branch" git -C "$repo" push -u origin "$branch"
          if ! (( DRY_RUN )) && ! on_origin "$repo" "$branch"; then
            say "branch $slug:$branch still not on origin — skipping PR this pass"
            continue
          fi
        fi
        # No commits ahead of main means there is no diff to propose and gh would
        # reject the PR. already_merged (patch-id) normally catches this first;
        # this is the reachability-only leftover. Same safe-delete path as above.
        if [[ "$(git -C "$repo" rev-list --count "origin/main..$branch" 2>/dev/null || echo 1)" == "0" ]]; then
          if [[ -n "$wt" ]] && ! git -C "$wt" diff --quiet 2>/dev/null; then
            say "MANUAL: branch $slug:$branch has nothing to PR but worktree has uncommitted changes — do not touch"
            continue
          fi
          [[ -n "$wt" ]] && run_action "worktree remove $slug:$branch" git -C "$repo" worktree remove --force "$wt"
          run_action "branch delete $slug:$branch" git -C "$repo" branch -D "$branch"
          say "$(past 'would delete' 'deleted') branch $slug:$branch — no commits vs main, nothing to PR (idle ${age}d)"
          continue
        fi
        # gh pr create --fill resolves git refs from the CURRENT directory, not
        # the target repo. The cron runs this script from a non-repo cwd, so
        # --fill fails with "could not compute title or body defaults". Compute
        # title/body explicitly from the repo instead.
        pr_title="$(git -C "$repo" log -1 --format=%s "$branch" 2>/dev/null || echo "sweep: $branch")"
        pr_body="$(git -C "$repo" log -1 --format=%b "$branch" 2>/dev/null | head -20 || true)"
        run_action "pr create $slug:$branch" gh pr create --repo "$slug" --head "$branch" --base main \
          --title "$pr_title" --body "${pr_body:-Automated PR from branch-sweep (day-3 rule).}"
        pr="$(open_pr "$slug" "$branch")"
        # ponytail: bounded CI wait so a stuck check can't wedge the cron; next
        # sweep picks the PR up if the wait expires.
        [[ -n "$pr" ]] && run_action "pr checks $slug#$pr" timeout "$CI_WAIT" gh pr checks "$pr" --repo "$slug" --watch
      fi
      if (( DRY_RUN )) && [[ -z "$pr" ]]; then
        say "would open PR, then merge+deploy $slug:$branch (day-3 rule)"
      elif [[ -n "$pr" ]] && pr_mergeable "$slug" "$pr"; then
        merge_and_deploy "$repo" "$slug" "$pr" "$branch"
      else
        say "branch $slug:$branch idle 3d, PR #${pr:-none} not mergeable (CI/review) — holding"
      fi
      continue
    fi

    if (( age >= 2 )); then
      say "branch $slug:$branch idle 2d — prune or deploy?"
    fi
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads)
}

for r in "${REPOS[@]}"; do
  sweep_repo "$r" || say "FAILED: sweep $r: pass aborted (exit $?)"
done

# The pass ran. Individual action failures were already reported per branch and
# must not turn into a cron-level failure — that only masks the report.
exit 0
