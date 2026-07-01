# AdVanced OS — Design Decisions

> Why we chose what we chose. Prevents re-litigation and keeps new contributors aligned.

## Architecture

### Decision: Three-Layer Architecture (Orchestration → Dispatch → Workers)

**Chosen:** Hermes as orchestrator, file-based tmux dispatch, independent workers.

**Rejected options:**
- **A2A protocol** — Designed for multi-runtime peer-to-peer. We have one serial tmux channel. Async request files are correct.
- **MCP server for Claude→Hermes** — Deadlock risk: Hermes blocks on tmux while Claude calls back into Hermes. Async shell commands avoid this.
- **AIOS / Agno / LangGraph** — In-process frameworks that own the LLM loop. Claude Code is a closed CLI. Tmux + cron + shell is correct.

**Rationale:** The serial tmux constraint drives everything. Adopting any framework that assumes it owns the runtime means either (a) wrapping Claude Code as a tool in that framework (worse than direct tmux), or (b) replacing Claude Code entirely (defeating the purpose). Our file-based pattern is deadlock-free and simple.

### Decision: Human-in-the-Loop, Not Autonomous

**Chosen:** Kevin approves every deploy, every significant decision routes to Discord.

**Rejected:** Full autonomous loop (deploy without approval, self-learning skill generation).

**Rationale:** Single-user system. The highest-leverage investment is the human-in-the-loop surface — clear deploy summaries, confirm-before-deploy, global stop button. Autonomous loops produce decisions Kevin would override anyway, adding noise and risk.

### Decision: Circuit Breaker Before Accelerator

**Chosen:** Phase 2 (circuit breaker) before Phase 1a (async shell bridge).

**Rationale:** Phase 1a ships `hermes-request research` which can trigger Hermes to dispatch again — a runaway loop. The circuit breaker (spend cap, dispatch depth, global stop) must exist before any dispatch automation.

## Memory

### Decision: Three Complementary Stores (Obsidian + OpenBrain + Hermes Memory)

**Chosen:** Obsidian vault (graph-linked, human-readable), OpenBrain MCP (vector-searchable, agent-fast), Hermes memory tool (compact cross-session facts).

**Rejected:** Single store for everything.

**Rationale:** Each store serves a different access pattern. Obsidian is for human browsing and long-term knowledge. OpenBrain is for agent-speed semantic retrieval. Hermes memory is for compact cross-session facts that need to be injected every turn. Using one store for all three would optimize for one pattern at the expense of the others.

### Decision: Compound Learning File (5d) Not a Self-Improvement Loop

**Chosen:** A flat markdown file that Hermes maintains and injects into task doc preambles.

**Rejected:** Automated self-improvement loop (reviewer agent merges duplicates, prunes stale entries, writes structured updates).

**Rationale:** Automated pruning produces noise Kevin hand-filters anyway. Manual curation is correct design. The compound learning file is machine-writeable for capture, human-curated for quality.

## Safety

### Decision: Stop State on Disk, Not in Memory

**Chosen:** Global stop flag persists to `/tmp/hermes-stop` or a DB row.

**Rationale:** The 5-minute watchdog restarts the session and would silently un-pause an in-memory stop flag. A stop Kevin can't trust is worse than none.

### Decision: Cooperative Halt

**Chosen:** Kill current dispatch should let the worker finish its current commit, then halt.

**Rationale:** A hard kill mid-write leaves a dirty git tree that violates deploy-checkout-hygiene and can wedge the next deploy.

### Decision: Depth Counter on Correlation ID

**Chosen:** The correlation ID carries the dispatch-depth counter.

**Rationale:** The circuit breaker needs to count across the async file boundary. Without a depth counter on the correlation ID, a chain of Hermes→Claude→hermes-request→Hermes dispatches again can't be bounded.

## Workers

### Decision: One General Worker, Not Specialized (Default)

**Chosen:** Every dispatch goes to the same Claude Code session with full tool access.

**Rejected (for now):** Tool-scoped worker profiles (research worker with Read-only, code-review worker with Git diff only).

**Rationale:** Only two profiles exist (default + ornith). Not enough worker diversity to need a tooling system. When context contamination or cost from using expensive models for cheap tasks becomes a problem, implement Phase 5f.

### Decision: Hermes-Managed Worker Profiles, Not Claude `.claude/agents/*.md`

**Chosen:** Hermes maintains a worker registry at `~/.hermes/workers/`. Each profile specifies tools, model, max turns.

**Rejected:** Claude Code's native `.claude/agents/*.md` subagent system.

**Rationale:** Claude's subagent system is tied to Anthropic's infra and assumes Claude is the orchestrator. Hermes worker profiles are infra-agnostic — they use `delegate_task` with toolset restrictions, which works with any backend model (DeepSeek, Claude, Gemini, local).

## QA

### Decision: Hermes Checks Concrete Success Criteria, Not Rubric-Driven LLM Grading

**Chosen:** Phase 5e — after worker signals completion, Hermes checks verifiable facts with shell commands (commit landed? Tests pass? Required files changed?).

**Rejected:** Anthropic's "Outcomes" pattern — a separate Claude instance evaluates output against a rubric in its own context window.

**Rationale:** Shell commands are cheaper, faster, and have no model bias. If a file exists or a test passes, we don't need an LLM to tell us. The only thing we lose is evaluation of subjective quality (code style, architectural fit), which is Kevin's job.

## Observability

### Decision: Structured Event Log, Not a Tracing DB

**Chosen:** Flat log file at `~/.hermes/logs/agent-events.log` with a structured format. Grepable by correlation ID, agent name, or event type.

**Rejected:** Formal tracing DB (OpenTelemetry, Jaeger, etc.).

**Rationale:** Correlation ID + grep is sufficient for a one-person system. A tracing DB adds infrastructure (collector, storage, query layer) for marginal benefit. When structured queries become necessary, the flat file can be imported into anything.

### Decision: Weekly Discord Summary, Not a Cost Dashboard

**Chosen:** Weekly Discord message: total spend, breakdown by worker, trend vs last week.

**Rejected:** Real-time cost dashboard UI.

**Rationale:** A dashboard adds a server process and visual polish but no new information. The data (parse Claude usage JSON + log) is the same. If Kevin starts asking about spend trends before the weekly summary naturally covers them, upgrade to a richer format — but not before.

## Do Not Build (Quick Reference)

See [DO_NOT_BUILD.md](DO_NOT_BUILD.md) for the full table with rationale.
