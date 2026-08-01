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

# run: perform a mutation, or describe it under --dry-run.
run() {
  if (( DRY_RUN )); then
    log "[dry-run] would run: $*"
    return 0
  fi
  "$@"
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
  run gh pr merge "$3" --repo "$2" --squash --delete-branch
  # ponytail: deploy is the repo's own pipeline if it has one; docs-only repos have none.
  if [[ -x "$1/scripts/auto-pr-pipeline.sh" ]]; then
    run bash "$1/scripts/auto-pr-pipeline.sh" deploy "$3"
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
      # Ancestry is a lie after a squash-merge: ask what commits are unique, not what merged.
      if [[ "$(git -C "$repo" rev-list --count "origin/main..$branch" 2>/dev/null || echo 1)" == "0" ]]; then
        [[ -n "$wt" ]] && run git -C "$repo" worktree remove --force "$wt"
        run git -C "$repo" branch -D "$branch"
        say "$(past 'would delete' 'deleted') verified-merged branch $slug:$branch (idle ${age}d)"
      else
        say "MANUAL: branch $slug:$branch idle 4wk, unique content"
      fi
      continue
    fi

    pr="$(open_pr "$slug" "$branch")"

    if (( age >= 14 )) && [[ -z "$pr" ]]; then
      run gh issue create --repo "$slug" --title "shelved: $branch" \
        --body "$(# shellcheck disable=SC2016  # printf format string, not an expansion
          printf 'Branch `%s` shelved by branch-sweep after %d days idle with no open PR.\n\nLast commit:\n\n```\n%s\n```\n\nWorktree removed; branch kept. Reopen by checking the branch out again.\n' \
          "$branch" "$age" "$(git -C "$repo" log -1 --format='%h %ad %an%n%n%s%n%n%b' --date=short "$branch" 2>/dev/null)")"
      [[ -n "$wt" ]] && run git -C "$repo" worktree remove --force "$wt"
      say "$(past 'would shelve' 'shelved') $slug:$branch (idle ${age}d, no PR) — issue filed, worktree removed, branch kept"
      continue
    fi

    if (( age >= 7 )) && [[ -z "$pr" ]]; then
      say "branch $slug:$branch idle 1wk, no PR — prune or PR?"
      continue
    fi

    if (( age >= 3 )); then
      if tier2 "$repo" "$branch"; then
        say "Tier 2 branch $slug:$branch idle 3d — deferred to docket"
        continue
      fi
      if [[ -z "$pr" ]]; then
        run gh pr create --repo "$slug" --head "$branch" --base main --fill
        pr="$(open_pr "$slug" "$branch")"
        # ponytail: bounded CI wait so a stuck check can't wedge the cron; next
        # sweep picks the PR up if the wait expires.
        [[ -n "$pr" ]] && run timeout "$CI_WAIT" gh pr checks "$pr" --repo "$slug" --watch >/dev/null 2>&1 || true
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
  sweep_repo "$r"
done
