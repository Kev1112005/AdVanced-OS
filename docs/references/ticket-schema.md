# Ticket Schema (Reference)

> Durable work-unit format for the Phase 5g async ticket surface.
> Source: loopOfLoopsResearch.md (the 20% that survived review).
> See PLAN.md Phase 5g and DO_NOT_BUILD.md for boundaries.

## Format

YAML frontmatter + Markdown body. Compatible with the Obsidian vault's markdown-based approach. Machine-parseable (frontmatter for status/routing) and human-readable (body for context/results).

## Fields

| Field | Purpose |
|-------|---------|
| `id` | Unique identifier (sequential or UUID) |
| `status` | `fresh` → `claimed` → `in_progress` → `pending_review` → `done` / `blocked` |
| `created` | ISO 8601 timestamp |
| `owner` | Worker or human who last touched it |
| `priority` | low / medium / high / critical |
| `Goal` | What success looks like — the outcome, not the instruction |
| `Context` | Links, files, memory references the worker needs |
| `Acceptance Criteria` | Concrete checks (gates the 5e QA gate runs against) |
| `Stop Conditions` | What the worker must NOT do (enforced by Hermes, not by the worker) |
| `Results` | Written by the worker after execution |

## Example

```markdown
---
id: "ticket-0001"
status: fresh
created: 2026-07-01T14:30:00Z
owner: ""
priority: medium
loop: "daily-triage"
---

# RSVP Check — Raid #42

## Goal
Check RSVP status for tonight's raid at 8PM CT. Report notable
drop-offs (signed up → cancelled) and bench availability.

## Context
- Event ID: 42
- Raid time: 2026-07-01T20:00:00-06:00
- Minimum required: 10 sign-ups

## Acceptance Criteria
- [ ] RSVP data retrieved from MCP
- [ ] Drop-offs >2 flagged with names
- [ ] Bench confirmed adequate
- [ ] Summary written to ticket

## Stop Conditions
- ⛔ Do not message raiders directly — report to ticket only
- ⛔ Do not modify event settings
- ⛔ If MCP is unavailable, mark ticket as blocked

## Results
<!-- Written by Hermes after execution -->
- RSVPs checked: 14 signed up, 2 cancelled
- Bench: 4 available — adequate
- Recommendation: Run as scheduled
```

## Design Rules

- **No LLM verifier.** Acceptance criteria are checked by the Phase 5e Hermes-run QA gate (shell commands).
- **No post-run critique.** Pattern accumulation goes in the compound learning file (5d), not auto-adjusted loop behavior.
- **No unattended tier.** L1 report-only only. Kevin reviews results before any action.
- **No token budgets.** The circuit breaker (Phase 2) owns spend cap + time cap globally.
- **Backend:** Start with a `tickets/` directory in the vault (simplest, git-backed). Upgrade to Linear via MCP only if Kevin needs querying/notifications.
