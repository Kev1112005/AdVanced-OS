# AdVanced OS — Implementation Plan

## The One Constraint That Drives Everything

**Claude Code is a REPL puppeted through a serial tmux session, not a service with an API.** This single fact breaks A2A/peer-to-peer/bidirectional framing. There is one puppet string. Design for one serial channel, not concurrent RPC.

## Core Design Rules

1. **Hermes does not write production code** — that's the worker's job, via task docs
2. **Workers do not trigger deploys, cron changes, or state mutations** — those are Hermes's job, behind Kevin's approval (tiered per Decision 010 — Tier 0/1 auto for bounded classes, Tier 2 always gated)
3. **No synchronous callbacks across the dispatch channel** — async request files only
4. **Small, idempotent, frequently-committed tasks** — the only reliable disaster recovery
5. **Kevin is the top of the architecture** — tiered autonomy per Decision 010; global stop overrides all tiers

## Current Status

| Phase | Status | Notes |
|------|--------|-------|
| Phase 2 | Complete | Circuit breaker, disk-backed global stop, depth gate, and spend-cap reader implemented |
| Phase 1b | Complete | Correlation IDs carry the dispatch depth |
| Phase 1c | Operator-disabled | Logger remains available, but automatic cost collection and GUI views are disabled because Claude development is subscription-backed |
| Phase 3 | Complete | Mission Control, provider registry, event log, status snapshot, durable orders, and operator controls implemented |
| Phase 4 | Complete | Durable Discord deploy summaries and immutable approve/deny decisions shared with Mission Control |
| Phase 1a | Complete | Async request/notification bridge and serial dispatch consumer implemented |
| Phase 5 | Operational | Alerting/backoff, QA delivery gate, compound learnings, and report-only ticket intake feed Mission Control |
| Phase 5f | Deferred stretch | Existing profiles remain manually configured; add more tool-scoped profiles only when worker diversity warrants it |
| Phase 6 | In progress | Tiered autonomy (Decision 010): daily branch sweep, Monday docket, approval-latency tier feedback |

## Interface Architecture

AdVanced OS has two complementary interfaces:

| Interface | Role | Technology |
|-----------|------|------------|
| **Mission Control GUI** | Awareness + trusted local control — monitor, dispatch, intervene, and approve | Static HTML + CSS + JS, polls JSON endpoints |
| **Discord CLI** | Complementary remote control — dispatch, approve, stop, configure | Hermes Agent via Discord |

The GUI is the primary interface and local control surface. The CLI remains the remote conversational surface. They share the same provider registry, durable order queue, event log, status snapshot, and safety state.

## Implementation Phases

### Phase 1b: Correlation ID (COMPLETE)

- `uuidgen` at the start of every user interaction (Kevin says X)
- Written into the session DB alongside each cron log and worker dispatch
- Not a tracing DB. A single UUID column in existing logs.
- Must carry the dispatch-depth counter for the circuit breaker (Phase 2)

### Phase 1c: Cost Logging (OPERATOR-DISABLED)

- Claude Code emits usage JSON in its status output
- Parse after each task: model, input tokens, output tokens, cache read/write, cost
- Append to a log file or session DB
- Feeds the GUI's spend-to-cap meters and per-worker cost breakdowns

`scripts/cost-log.sh` remains available, and the circuit breaker can read its CSV.
Automatic collection and Mission Control cost views are disabled because Claude
development is subscription-backed and the telemetry was not useful to Kevin.

### Phase 2: Circuit Breaker (COMPLETE)

**The single most important safety item. All automation is gated behind this.**

1. **Spend cap** — Per-week dollar limit. Hermes stops dispatching when hit. Kevin alerted.
2. **Max dispatch depth** — Limit of 3 chained dispatches from a single request. Kill at 4.
3. **Global stop** — `/stop-hermes`. Pauses cron, kills current dispatch, prevents new ones. **Flag on disk** (not memory — watchdog would silently un-pause).
4. **Time cap** — If task exceeds N minutes, checkpoint and ask Kevin to confirm continue.
5. **Cooperative halt** — Kill must let current commit finish before hard-stopping.

### Phase 3: Mission Control GUI (COMPLETE)

**The core interface of the operating system.** A visual dashboard showing every agent, every task, every cost, and every system health metric in one browser tab.

**Prerequisites:** Phase 1b (correlation ID), Phase 1c (cost logging), Phase 2 (circuit breaker)

**Data layer (ships as part of this phase):**
- **Structured observability (5a):** Event log at dispatch/complete/fail/qa_pass/qa_fail/circuit_break boundaries. Flat file at `~/.hermes/logs/agent-events.log`. Format: `[timestamp] <correlation_id> <event_type> <agent> <detail>`.
- **Agent status snapshot (5b):** Hermes writes `~/.hermes/status/current.json` on each dispatch and completion. Contains: active tmux sessions, their last-known phase, cron job health, dispatch depth, spend-to-cap.
- **Cost data:** Per-worker cost totals, weekly spend, trend vs last week. Derived from Phase 1c log.

**GUI itself:**
- Single static HTML page with inline CSS and JS
- Polls `/api/status` (reads current.json) and `/api/events` (tails agent-events.log) every 5 seconds
- Served by a lightweight HTTP server (Python http.server or a 10-line Express app)
- No database, no build step, no dependencies beyond what's already in the system

**Dashboard layout:**
- **Top bar:** System health indicator, circuit breaker status (OK/WARNING/TRIPPED), spend-to-cap meter
- **Worker panel:** Grid of worker cards showing name, status (active/idle/error), current task, duration, worker type
- **Event feed:** Scrolling list of recent events, filterable by worker, with correlation ID links
- **Cost panel:** Weekly spend bar with cap line, per-worker breakdown, trend arrow vs last week
- **Cron panel:** Scheduled job health — last run time, success/failure status per job

**Not building (Phase 3 scope):**
- No real-time WebSockets. 5-second polling is sufficient for at-a-glance awareness.
- No authentication. Single-user, local-only. Reverse proxy handles auth if exposed.
- No mobile app. The Discord CLI is the mobile interface.

### Phase 4: Discord Approval UX (COMPLETE)

The control surface to complement the GUI's awareness:
- **Clear deploy notifications** — "PR #N merged. Build passing. Deploy? (yes/no/notify)"
- **Confirm-before-deploy** with risk summary (schema change? new dep? config?)
- **Cost alert** — "Weekly spend at 80% of cap. This task: $X. Continue?"
- **Workflow status** — "Worker phase: committing. ETA: ~2 min."
- **Global stop button** — Always available, always visible

Implementation:

- `scripts/deploy-approval.sh` owns durable request, notify, decide, status,
  list, and pre-deploy check operations.
- `skills/deployment-approval/SKILL.md` maps Kevin's explicit Discord wording to
  the durable decision command.
- Mission Control reads and decides against the same request and approval
  directories.
- Decisions are immutable and idempotent. Approval records never execute a
  deployment.

### Phase 1a: Async Shell Bridge (COMPLETE)

Two shell commands workers can call asynchronously (gated behind circuit breaker):

1. `hermes-request <type> "<payload>"` — Writes request to `/tmp/hermes-requests/<uuid>.json`, returns immediately. Types: `research`, `notify`, `log`.
2. `hermes-notify "<message>"` — Fire-and-forget. Writes to a file Hermes surfaces to Kevin.

~20 lines of shell script + 2 cron-like file watchers. No MCP server needed.

### Phase 5: Production Hardening (LOW — as needed)

- **Graceful degradation:** If MCP is down → alert + back off. Rate-limited → wait + retry. Model unavailable → fallback model.
- **Session checkpointing:** NOT building. It's a fiction. DR = small, committed, idempotent tasks.

### Phase 5d: Compound Learning File (COMPLETE)

A `~/hermes-learnings.md` file that accumulates cross-session patterns, gotchas, and conventions. Hermes maintains the file, reads it before dispatch, and injects relevant learnings into the task document preamble. Kevin prunes it like skills — manual curation is correct.

### Phase 5e: Hermes-Run QA Gate (COMPLETE)

After Claude finishes a task but before Hermes accepts delivery, Hermes evaluates the output against the task document's success criteria using shell commands. Commit landed? Tests pass? Required files changed? If criteria aren't met, Hermes sends the failure analysis back to Claude for another pass.

### Phase 5f: Tool-Scoped Worker Profiles (LOW — half day, stretch)

Tool-scoped worker profiles that Hermes can dispatch via `delegate_task` with restricted tool sets. Research (Read/Glob/Grep/Web, no Write), code-review (Read/Glob/Grep/Git, no Bash), general (full tools). Hermes maintains a registry at `~/.hermes/workers/`.

### Phase 5g: Async Ticket Surface (COMPLETE)

Kevin drops tickets into a `tickets/` vault directory; Hermes scans on cron, dispatches through the serial channel with circuit-breaker lock held. Verification via the 5e shell gate. No LLM verifier, no post-run critique, no unattended tier.

## Success Metrics

| Metric | Target | Triggers At |
|--------|--------|-------------|
| Cost visibility | GUI shows spend-to-cap at a glance without asking | Phase 3 |
| Agent visibility | GUI shows every worker's status without tmux capture-pane | Phase 3 |
| Workless watchdog restarts | <1 per week where long task loses progress | Idempotent-task discipline |
| Crash recovery | Claude session dies → recover <2 min | Small-commits rule |
| Approval confidence | Kevin says yes/no to deploy in <5 seconds | Phase 4 |

## Landscape Gap Summary

| Feature | Our State | Action | Priority |
|---------|-----------|--------|----------|
| Mission Control dashboard | No visual dashboard. Terminal-only. | Phase 3 — core deliverable. GUI is the primary interface. | **CORE** |
| Structured observability | Correlation ID, no structured format. | Phase 3 data layer — event log at dispatch/complete/fail boundaries. | CORE |
| Cost analytics dashboard | No visual cost display. | Phase 3 GUI — spend-to-cap meters, per-worker breakdowns, trend lines. | CORE |
| Hermes-run QA gate | Concrete delivery checks and immutable results feed Mission Control. | Operate through `qa-gate.sh`; keep checks shell-verifiable. | COMPLETE |
| Tool-scoped worker profiles | Every dispatch to same general worker. | Phase 5f — worker registry with restricted toolsets. | STRETCH |
| Compound learning | Append-only, human-curated file is injected into task docs. | Curate in Mission Control or `compound-learning.sh`. | COMPLETE |
| Async ticket surface | Report-only vault tickets share the existing serial consumer poll. | Kevin reviews every result in Mission Control. | COMPLETE |
| Subagent/profile spawning | Manually wired as needed. | Manual `hermes setup` until >5 profiles. | NOT NEEDED |
| One-click backup/restore | Manual backup only. | Not needed until complexity justifies it. | NOT NEEDED |
| Loop self-critique / maker-checker LLM verifier | Not proposed. | DO_NOT_BUILD — duplicates Decisions 006 & 007. | NOT NEEDED |

## Roadmap

```
Day 1    Phase 2  — Circuit breaker (spend cap, dispatch-depth limit, global stop on disk)
         Phase 1b — Correlation ID (uuidgen in logs, carries depth counter)
         Phase 1c — Cost logging (parse usage JSON → log)

Day 2    Phase 3  — Mission Control GUI
             5a  Structured observability (event log)
             5b  Agent status snapshot (JSON endpoint)
             Mission Control HTML page (the dashboard)
                     Requires: Phase 2, 1b, 1c

Day 3    Phase 4  — Discord approval UX (deploy summaries, confirm-before-deploy)
         Phase 1a — Async shell bridge (hermes-request, hermes-notify)
                     Gated behind circuit breaker.

Day 4+   Phase 5  — Production hardening. Anything that actually hurts.

Optional:
   5d  Compound learning file (30 min)
   5e  Hermes-run QA gate (30 min)
   5f  Tool-scoped worker profiles (half day — stretch)
   5g  Async ticket surface (half day)
```

Total core: ~3 days. The GUI ships on day 2.
