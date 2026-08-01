#!/usr/bin/env bash
# docket-prep.sh — Monday docket context (Decision 010, tiered autonomy).
#
# Output is DATA for an agent cron to interpret, not prose for a human. Prints
# markdown sections only; empty sections say "none" and nothing else.
#
#   docket-prep.sh [repo ...]
#
# Env: HERMES_SWEEP_REPOS, HERMES_DEPLOY_REQUEST_DIR, HERMES_APPROVAL_DIR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
DEPLOY_DIR="${HERMES_DEPLOY_REQUEST_DIR:-$HOME/.hermes/deploy-requests}"
APPROVAL_DIR="${HERMES_APPROVAL_DIR:-$HOME/.hermes/approvals}"
DEFAULT_REPOS="$HOME/ObsoleteBot $HOME/AdVanced-OS"

read -r -a REPOS <<< "${*:-${HERMES_SWEEP_REPOS:-$DEFAULT_REPOS}}"

slug_of() {
  git -C "$1" remote get-url origin 2>/dev/null \
    | sed -E 's#\.git$##; s#.*[:/]([^/]+/[^/]+)$#\1#'
}

since="$(date -u -d '7 days ago' +%F)"

echo "## Merged last 7 days"
echo
merged=0
for repo in "${REPOS[@]}"; do
  slug="$(slug_of "$repo")" || continue
  [[ -n "$slug" ]] || continue
  while IFS=$'\t' read -r num title at; do
    [[ -n "$num" ]] || continue
    echo "- $slug#$num — $title (merged $at)"
    merged=1
  done < <(gh pr list --repo "$slug" --state merged --limit 100 \
    --search "merged:>=$since" --json number,title,mergedAt \
    --jq '.[] | [.number, .title, .mergedAt] | @tsv' 2>/dev/null || true)
done
(( merged )) || echo "none"
echo

echo "## Open PRs"
echo
open_any=0
for repo in "${REPOS[@]}"; do
  slug="$(slug_of "$repo")" || continue
  [[ -n "$slug" ]] || continue
  while IFS=$'\t' read -r num title head mergeable; do
    [[ -n "$num" ]] || continue
    if gh pr checks "$num" --repo "$slug" >/dev/null 2>&1; then ci=green; else ci=not-green; fi
    echo "- $slug#$num — $title (head: \`$head\`, ci: $ci, mergeable: $mergeable)"
    open_any=1
  done < <(gh pr list --repo "$slug" --state open --limit 100 \
    --json number,title,headRefName,mergeable \
    --jq '.[] | [.number, .title, .headRefName, .mergeable] | @tsv' 2>/dev/null || true)
done
(( open_any )) || echo "none"
echo

echo "## Queued Tier 2 approvals"
echo
queued=0
shopt -s nullglob
for req in "$DEPLOY_DIR"/*.json; do
  id="$(basename "$req" .json)"
  if [[ -f "$APPROVAL_DIR/$id.json" ]]; then continue; fi
  jq -r --arg id "$id" \
    '"- \($id) — \(.title // "untitled") [risk: \(.risk // "?")] requested \(.created_at // "?")"' \
    "$req" 2>/dev/null || echo "- $id — unreadable request record"
  queued=1
done
shopt -u nullglob
(( queued )) || echo "none"
echo

echo "## Idle branches (>= 2 days)"
echo
# ponytail: reuse the sweep's own ladder rather than re-deriving ages here.
idle="$(HERMES_SWEEP_LOG=/dev/null bash "$SCRIPT_DIR/branch-sweep.sh" --dry-run "${REPOS[@]}" 2>/dev/null || true)"
if [[ -n "$idle" ]]; then
  while IFS= read -r line; do echo "- $line"; done <<< "$idle"
else
  echo "none"
fi
echo

echo "## Approval latency"
echo
DEPLOY_DIR="$DEPLOY_DIR" APPROVAL_DIR="$APPROVAL_DIR" python3 - <<'PY'
import glob, json, os, statistics
from datetime import datetime, timezone

CLASSES = [
    ("schema", ("schema", "migration", "prisma")),
    ("auth", ("auth", "login", "session", "permission")),
    ("secrets", ("secret", "env var", "credential", "token")),
    ("user-ping", ("notify", "ping", "announce", "broadcast")),
    ("docs", ("doc", "readme", "agents.md")),
]

def classify(title):
    low = title.lower()
    for name, words in CLASSES:
        if any(w in low for w in words):
            return name
    return "other"

def parse(ts):
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None

def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None

rows = []
for req_path in sorted(glob.glob(os.path.join(os.environ["DEPLOY_DIR"], "*.json"))):
    ident = os.path.basename(req_path)[:-5]
    req = load(req_path)
    dec = load(os.path.join(os.environ["APPROVAL_DIR"], ident + ".json"))
    if not req or not dec:
        continue
    created, decided = parse(req.get("created_at")), parse(dec.get("decided_at"))
    if not created or not decided:
        continue
    title = req.get("title", ident)
    rows.append((ident, title, classify(title), dec.get("decision", "?"),
                 (decided - created).total_seconds() / 60))

if not rows:
    print("none")
else:
    for ident, title, klass, decision, mins in rows:
        print(f"- {ident} — {title} [class: {klass}, decision: {decision}, latency: {mins:.0f} min]")
    print()
    print("### Tier-bump candidates (count >= 3, median latency < 60 min)")
    print()
    by_class = {}
    for _, _, klass, _, mins in rows:
        by_class.setdefault(klass, []).append(mins)
    hits = [(k, v) for k, v in sorted(by_class.items())
            if len(v) >= 3 and statistics.median(v) < 60]
    if hits:
        for klass, mins in hits:
            print(f"- {klass} — n={len(mins)}, median {statistics.median(mins):.0f} min "
                  f"(propose Tier 2 -> 1)")
    else:
        print("none")
PY
