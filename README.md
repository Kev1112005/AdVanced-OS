# AdVanced OS

**A Hermes-based Agentic Operating System** — the orchestration, memory, and observability layer that turns scattered AI tools into a coordinated system. Kevin orchestrates. Hermes routes. Workers execute.

## What This Is

AdVanced OS is the infrastructure layer that gives AI agents persistent memory, structured planning, disciplined execution, and safe production deployment. Without it, every agent session starts from zero: no context, no state, no shared understanding. With it, agents build on previous work, decisions compound, and the system gets smarter over time.

## What This Is Not

- Not an agent framework (LangGraph, CrewAI, AIOS) — those own the LLM loop. We don't.
- Not a coding agent (Claude Code, Codex, opencode) — those write code. We orchestrate them.
- Not a GUI dashboard (for now) — the control surface is Discord + terminal. A visual layer is a stretch goal.
- Not an Anthropic product — Claude is one worker among many. The OS is built around Hermes.

## Core Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                       KEVIN                                   │
│  ┌─────────────────────┐    ┌──────────────────────────────┐ │
│  │ Mission Control GUI  │    │    Discord CLI              │ │
│  │ (local command)      │    │ (remote command)            │ │
│  │ • Provider status    │    │ • Conversational dispatch   │ │
│  │ • Task queue + vox   │    │ • Remote approvals          │ │
│  │ • Deploy approvals   │    │ • Global stop               │ │
│  │ • Event chronicle    │    │ • Configure                 │ │
│  └─────────┬───────────┘    └──────────┬───────────────────┘ │
└────────────┼───────────────────────────┼─────────────────────┘
             │                           │
┌────────────▼───────────────────────────▼─────────────────────┐
│                  HERMES (Orchestrator)                        │
│   • Task decomposition & routing                              │
│   • Research & design review (DeepSeek V4 Pro)                │
│   • Agent dispatch & monitoring                               │
│   • Cron scheduling                                           │
│   • Post-merge deploy pipeline                                │
└──────────────────┬───────────────────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────────────────┐
│              DISPATCH LAYER                                    │
│   • tmux session → Claude Code (coding worker)                 │
│   • delegate_task → Hermes subagents (research, review)        │
│   • cron → shell scripts (scheduled tasks)                     │
│   • File-based async bridge (hermes-request / hermes-notify)   │
│   No concurrent RPC. No synchronous callbacks.                 │
└──────────────────┬───────────────────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────────────────┐
│              WORKER LAYER                                      │
│   • Claude Code — production code, PRs, tests                 │
│   • DeepSeek V4 Pro — design review, research                 │
│   • Cron — scheduled maintenance, monitoring, reports         │
│   • MCP servers — ObsoleteBot guild data, OpenBrain memory    │
│   • Workers cannot trigger deploys, cron, or state mutations  │
└──────────────────────────────────────────────────────────────┘
```

## Design Principles

1. **The GUI is the primary interface** — Mission Control shows every provider, agent, task, and event, and exposes explicit local controls. Discord remains the complementary remote interface.
2. **Hermes does not write production code** — that's the worker's job, via task docs
3. **Workers do not trigger deploys, cron changes, or state mutations** — those are Hermes's job, behind Kevin's approval
4. **No synchronous callbacks across the dispatch channel** — async request files only
5. **Small, idempotent, frequently-committed tasks** — the only reliable disaster recovery
6. **Kevin is the top of the architecture** — every significant decision, deploy, or mutation routes to Discord for approval
7. **Circuit breaker outranks every other feature** — spend cap, dispatch-depth limit, persistent global stop
8. **Build the brakes before the accelerator** — safety before autonomy

## Key Features

| Feature | Status | Phase |
|---------|--------|-------|
| Circuit breaker (spend cap, dispatch depth, global stop) | Planned | Phase 2 |
| Correlation ID tracing | Planned | Phase 1b |
| Cost logging (per-task, GUI-displayed spend meters) | Planned | Phase 1c |
| **Mission Control GUI** (provider registry, task queue, live output, event feed, controls) | **Implemented** | **Phase 3** |
| Provider registry (Codex, Claude Code, Hermes) | Implemented | Phase 3 |
| Structured observability (event log feeding the GUI) | Planned | Phase 3 |
| Agent status snapshot (JSON endpoint for GUI) | Planned | Phase 3 |
| Discord approval UX (deploy summaries, confirm-before-deploy) | Planned | Phase 4 |
| Async shell bridge (hermes-request, hermes-notify) | Planned | Phase 1a |
| Production hardening (graceful degradation) | Planned | Phase 5 |
| Hermes-run QA gate (success criteria verification) | Planned | Phase 5e |
| Compound learning file (cross-session pattern accumulation) | Planned | Phase 5d |
| Tool-scoped worker profiles (research/code-review/general) | Stretch | Phase 5f |
| Async ticket surface (vault-based tickets) | Planned | Phase 5g |
## Quick Start

```bash
# Prerequisites: Hermes Agent installed and configured
# https://hermes-agent.nousresearch.com/docs

# Clone the OS config
git clone https://github.com/Kev1112005/AdVanced-OS.git
cd AdVanced-OS

# Review the plan
cat PLAN.md

# Check current architecture
cat ARCHITECTURE.md

# Understand design decisions
cat DESIGN_DECISIONS.md

# See what NOT to build
cat DO_NOT_BUILD.md
```

## Directory Structure

```
AdVanced-OS/
├── README.md                 # This file
├── AGENTS.md                 # What developer agents need to know
├── ARCHITECTURE.md           # Detailed architecture documentation
├── PLAN.md                   # Full implementation plan and roadmap
├── DESIGN_DECISIONS.md       # Key design decisions and rationale
├── DO_NOT_BUILD.md           # Explicit "do not build" list
├── CONTRIBUTING.md           # Guidelines for agent contributors
├── docs/
│   ├── references/           # External reference material
│   ├── decisions/            # Decision records
│   └── worker-profiles/      # Worker profile definitions
```

## The Orchestrator

AdVanced OS is built around **Hermes Agent** (by Nous Research). Hermes is the orchestrator — it decomposes tasks, dispatches to workers, monitors progress, and reports results. The OS extends Hermes with:

- **Circuit breaker safety** — prevents runaway spend and dispatch loops
- **Structured observability** — knows which agent did what, when, and with what result
- **Worker profiles** — tool-scoped dispatch targets for research, review, and coding
- **Compound learning** — cross-session pattern accumulation injected into every task
- **QA gates** — automated success criteria verification before accepting delivery

## Status

**Phase:** Design / Scaffolding

The architecture is documented, the plan is finalized, and the implementation order is set. Build starts with the circuit breaker (Phase 2) — everything else follows.

See [PLAN.md](PLAN.md) for the full roadmap.
