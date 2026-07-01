# AdVanced OS — Implementation Plan

## The One Constraint That Drives Everything

**Claude Code is a REPL puppeted through a serial tmux session, not a service with an API.** This single fact breaks A2A/peer-to-peer/bidirectional framing. There is one puppet string. Design for one serial channel, not concurrent RPC.

## Core Design Rules

1. **Hermes does not write production code** — that's the worker's job, via task docs
2. **Workers do not trigger deploys, cron changes, or state mutations** — those are Hermes's job, behind Kevin's approval
3. **No synchronous callbacks across the dispatch channel** — async request files only
4. **Small, idempotent, frequently-committed tasks** — the only reliable disaster recovery
5. **Kevin is the top of the architecture** — every significant decision, deploy, or mutation routes to Discord for approval

## Implementation Phases

### Phase 1b: Correlation ID (CHEAP — 30 minutes)

- `uuidgen` at the start of every user interaction (Kevin says X)
- Written into the session DB alongside each cron log and worker dispatch
- Not a tracing DB. A single UUID column in existing logs.
- Must carry the dispatch-depth counter for the circuit breaker (Phase 2)

### Phase 1c: Cost Logging (CHEAP — 30 minutes)

- Claude Code emits usage JSON in its status output
- Parse after each task: model, input tokens, output tokens, cache read/write, cost
- Append to a log file or session DB
- Weekly summary delivered to Discord: "This week: $X across Y tasks. Breakdown by worker."

### Phase 2: Circuit Breaker (HIGH — half a day) — BUILD THIS FIRST

**The single most important safety item. The accelerator (Phase 1a) must never exist without brakes.**

1. **Spend cap** — Per-week dollar limit. Hermes stops dispatching when hit. Kevin alerted.
2. **Max dispatch depth** — Limit of 3 chained dispatches from a single request. Kill at 4.
3. **Global stop** — `/stop-hermes`. Pauses cron, kills current dispatch, prevents new ones. **Flag on disk** (not memory — watchdog would silently un-pause).
4. **Time cap** — If task exceeds N minutes, checkpoint and ask Kevin to confirm continue.
5. **Cooperative halt** — Kill must let current commit finish before hard-stopping.

### Phase 1a: Async Shell Bridge (MEDIUM — half a day)

Two shell commands workers can call asynchronously (gated behind circuit breaker):

1. `hermes-request <type> "<payload>"` — Writes request to `/tmp/hermes-requests/<uuid>.json`, returns immediately. Types: `research`, `notify`, `log`.
2. `hermes-notify "<message>"` — Fire-and-forget. Writes to a file Hermes surfaces to Kevin.

~20 lines of shell script + 2 cron-like file watchers. No MCP server needed.

### Phase 3: Discord Approval UX (MEDIUM — 1 day)

Make the human-in-the-loop surface excellent:
- **Clear deploy notifications** — "PR #N merged. Build passing. Deploy? (yes/no/notify)"
- **Confirm-before-deploy** with risk summary (schema change? new dep? config?)
- **Cost alert** — "Weekly spend at 80% of cap. This task: $X. Continue?"
- **Workflow status** — "Worker phase: committing. ETA: ~2 min."
- **Global stop button** — Always available, always visible

### Phase 4: Production Hardening (LOW — as needed)

- **Graceful degradation:** If MCP is down → alert + back off. Rate-limited → wait + retry. Model unavailable → fallback model.
- **Spend dashboard:** Weekly Discord message. Not a real dashboard.
- **Session checkpointing:** NOT building. It's a fiction. DR = small, committed, idempotent tasks.

### Phase 5: Landscape Gaps (optional — 1-2 days total)

All gated behind the circuit breaker. Build only when needed.

| # | Item | Time | Value | When to Build |
|---|------|------|-------|---------------|
| 5a | Structured observability — event log at dispatch/complete/fail boundaries | Half day | High | Anytime — cheap, enables "what happened yesterday" queries |
| 5b | Agent status snapshot — `hermes status` command | 30 min | Medium | Anytime — makes "what's running now" Discord-answerable |
| 5c | Mission Control HTML page — visual dashboard | 1 day | Stretch | Only if Kevin wants a browser tab (5a+5b cover same info) |
| 5d | Compound learning file — Hermes-curated cross-session patterns | 30 min | Medium | Anytime — Hermes injects relevant learnings into task docs |
| 5e | Hermes-run QA gate — success criteria checked after worker finishes | 30 min | High | After Phase 3 — catches delivery failures before Kevin sees them |
| 5f | Tool-scoped worker profiles — research/code-review workers with restricted tools | Half day | Stretch | Only when context contamination or cost becomes a problem |

## Success Metrics

| Metric | Target | Triggers At |
|--------|--------|-------------|
| Cost visibility | Kevin knows weekly spend without asking | Phase 1c |
| Workless watchdog restarts | <1 per week where long task loses progress | Idempotent-task discipline |
| Crash recovery | Claude session dies → recover <2 min | Small-commits rule |
| Approval confidence | Kevin says yes/no to deploy in <5 seconds | Phase 3 |

## Landscape Gap Summary

| Feature | Our State | Action | Priority |
|---------|-----------|--------|----------|
| Mission Control dashboard | No visual dashboard. Terminal-only. | 5a+5b first. 5c stretch. | LOW |
| Structured observability | Correlation ID, no structured format. | 5a — ~50 lines of shell wrappers. | MEDIUM |
| Hermes-run QA gate | Manual verification only. | 5e — success criteria checked after worker signals completion. | MEDIUM |
| Tool-scoped worker profiles | Every dispatch to same general worker. | 5f — worker registry with restricted toolsets. | STRETCH |
| Compound learning | Manual skill curation. No cross-session file. | 5d — Hermes-curated, injected into task docs. | LOW |
| Cost analytics dashboard | Weekly Discord text summary only. | Phase 1c is sufficient. | NOT NEEDED |
| Subagent/profile spawning | `ornith` manually wired. | Manual `hermes setup` until >5 profiles. | NOT NEEDED |
| One-click backup/restore | Manual backup only. | Not needed until complexity justifies it. | NOT NEEDED |
| Agent org chart | Not documented. | ARCHITECTURE.md + docs/worker-profiles/ covers this. | DONE |

## Roadmap

```
Day 1    Phase 2  — Circuit breaker (spend cap, dispatch-depth limit, global stop on disk)
         Phase 1b — Correlation ID (uuidgen in logs, carries depth counter)
         Phase 1c — Cost logging (parse usage JSON → log)

Day 2    Phase 1a — Async shell bridge (hermes-request, hermes-notify)
                     Gated behind circuit breaker.

Day 3    Phase 3  — Discord approval UX (deploy summaries, confirm-before-deploy)

Day 4+   Phase 4  — Production hardening. Anything that actually hurts.

Optional Phase 5:
   5a  Structured observability (half day)
   5b  Agent status snapshot (30 min)
   5c  Mission Control HTML page (1 day — stretch)
   5d  Compound learning file (30 min)
   5e  Hermes-run QA gate (30 min)
   5f  Tool-scoped worker profiles (half day — stretch)
```

Total core: ~3 days. Phase 5 adds ~1-2 optional days.
