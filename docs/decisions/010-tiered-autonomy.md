# Decision: Tiered Autonomy

- **Date:** 2026-07-31
- **Status:** Approved
- **Supersedes:** Decision 003 (Option-1-only: "Kevin approves every deploy, no exceptions")
- **Context:** Deploy authorization and system autonomy boundaries

## Context

Decision 003 chose human-in-the-loop for every deploy: Kevin approves all, no exceptions. Operation since then showed the cost: Kevin became the rate-limiter for the entire pipeline. On 2026-07-31 a single close-the-loop session found 73 branches and 28 worktrees accumulated, merged PRs (#473/#475) stranded in main for over an hour because the deploy checkout was dirty, and sessions routinely ending at "Kevin didn't respond within 10 minutes." Meanwhile the ObsoleteBot pipeline already auto-merges and auto-deploys every merge — autonomy exists, but it is accidental and unbounded rather than designed.

Kevin's explicit direction: the codebase belongs to the AI agents. Properly-tested bug fixes need no human gate. Features should flow with visibility. Only risky classes (schema, auth, secrets, user-facing pings) stay human-gated.

## Options Considered

1. **Keep 003 as-is** — Kevin approves every deploy. Proven to bottleneck the pipeline and accumulate backlog.
2. **Full autonomy** — no gates anywhere. Rejected: 003's concern stands for the risky classes; a bad migration or a stray user-ping has no second set of eyes.
3. **Tiered bounded autonomy** — deterministic tier boundaries (change class by path, diff size, CI/review state — NOT a learned risk classifier), aggressive idle deadlines, and an approval-latency feedback loop that adjusts tiers. This is the chosen approach.

## Chosen Approach

Three tiers, deterministic boundaries:

| Tier | Content | Merge | Deploy | Kevin |
|------|---------|-------|--------|-------|
| 0 — Auto | Docs/AGENTS.md/README; bug fixes with proper tests (CI green, code+security review clean) | Auto | Auto (docs = no deploy) | Not involved |
| 1 — Docket | Features, refactors, new commands | Auto (CI + review clean) | Auto | Monday docket visibility; can hold anything |
| 2 — Approval | Schema migrations, auth/security-critical, secrets/env vars, anything that pings users | Blocked | Blocked | Existing immutable approve/deny UX |

Tier classification is deterministic: path patterns (api/prisma/, auth, docker-compose env vars, notification code) + test coverage + CI/review state. No learned classifier.

### Idle-branch deadlines (daily sweep)

| Idle | Action |
|------|--------|
| 2 days | Message Kevin: prune or deploy? |
| 3 days, no response | Auto-merge + deploy (Tier 0/1 class only; Tier 2 NEVER auto-approves — defers to docket) |
| 1 week, no PR | Message Kevin |
| 2 weeks | Shelve: create GitHub issue (branch summary, last commit, why), delete worktree, keep branch |
| 4 weeks | Content-verify (rebase-empty / git log -S test), then delete branch + worktree |

Content-verification is MANDATORY before any deletion — a branch whose content is already in main (squash-merge rewrites SHAs; ancestry is a lie) is deleted freely; a branch with unique content is never auto-deleted, only shelved.

### Approval-latency feedback loop

Every Kevin approval is logged (existing deployment-approval records). The docket prep analyzes latency + theme: change classes approved instantly and repeatedly are proposed for tier bump (Tier 2 → 1, etc.). Kevin ratifies bumps on the Monday docket. Tiers are human-ratified, machine-suggested.

## Rationale

- 003's rejection of "conditional autonomy" was about a fuzzy risk classifier. Tier boundaries here are deterministic and auditable — a path pattern or a test count is not a judgment call.
- The pipeline already auto-deploys. Formalizing tiers converts accidental autonomy into bounded, visible, reversible autonomy.
- Kevin remains the top of the architecture: global stop, circuit breaker, immutable Tier 2 approvals, hold-anything docket, and human-ratified tier changes.
- Aggressive idle deadlines (2 days, not 2 weeks) match Kevin's ADHD-friendly operating style: close loops fast or close them for him.

## Consequences

- Tier 0/1 deploys no longer wait on Kevin. Deploy speed is pipeline speed.
- Tier 2 remains a hard gate — the existing approval UX is unchanged.
- A daily sweep + Monday docket run via cron (Hermes-run; workers never mutate cron/state per PLAN.md).
- Decision 003's "no exceptions" language is superseded; its guardrails (global stop, spend cap, no cron mutation by workers) remain.
