# AdVanced OS Architecture

## Overview

AdVanced OS is a four-layer architecture: **Interface → Orchestration → Dispatch → Workers**. Kevin interacts through two complementary interfaces — the Mission Control GUI (awareness) and the Discord CLI (control). The entire system is designed around one hard constraint: **a single serial tmux channel to the primary coding worker (Claude Code)**.

## The Four Layers

### Layer 0: Interface

Two complementary interfaces sit above the orchestrator. They share the same backend data but serve different purposes:

| Interface | Role | Technology | Use When |
|-----------|------|------------|----------|
| **Mission Control GUI** | Awareness — at-a-glance status of all agents, tasks, costs, and system health | Static HTML + CSS + JS, polls JSON endpoints | Sitting at a desk, want to see everything at once |
| **Discord CLI** | Control — dispatch, approve deploys, stop, configure | Hermes Agent via Discord | On mobile, in a meeting, or when an action is faster by keyboard |

The GUI is the primary interface — the operating system's main display. The CLI is the control surface for actions that are faster by keyboard. They share the same data sources (event log, status snapshot, cost log) and are consistent with each other.

### Layer 1: Orchestration (Hermes)

Hermes is the orchestrator. It receives tasks from Kevin (via Discord), decomposes them, routes them to the appropriate worker, monitors execution, and reports results. Hermes also manages cron scheduling, cost tracking, and the deploy pipeline.

**Responsibilities:**
- Task decomposition & routing
- Research & design review (via DeepSeek V4 Pro subagent)
- Agent dispatch & monitoring
- Cron scheduling
- Post-merge deploy pipeline
- Circuit breaker enforcement (spend cap, dispatch depth, global stop)
- Structured observability (event logging)
- QA gate execution (success criteria verification)

**NOT responsible for:**
- Writing production code (that's the worker's job)
- Code review gating (routed through Kevin)
- Deploy go/no-go decisions (Kevin approves)
- Final architectural decisions (Kevin decides)

**Runs on:** DeepSeek V4 Flash/Pro via Hermes Agent CLI (Discord)

### Layer 2: Dispatch

The dispatch layer is the communication channel between Hermes and its workers. It is intentionally simple — no concurrent RPC, no bidirectional callbacks, no peer-to-peer messaging.

**Dispatch methods:**

| Method | Target | Use Case | Constraint |
|--------|--------|----------|------------|
| tmux session → Claude Code | Claude Code (primary coding worker) | Feature dev, bug fixes, PRs | One session at a time. Serial dispatch only. |
| delegate_task | Hermes subagents (any model) | Research, design review, parallel exploration | Subagents cannot dispatch further. No tool access to deploys. |
| cron | Shell scripts | Scheduled tasks, monitoring, reports | No interaction with active tmux session. |
| File-based async bridge | Claude Code → Hermes | Worker→Orchestrator communication | Fire-and-forget only. No synchronous response expected. |

**Critical rule:** Workers CANNOT trigger deploys, cron changes, or state mutations. Those are Hermes's job, behind Kevin's approval. The only exception is `hermes-request` (research) and `hermes-notify` — fire-and-forget messages that Hermes picks up asynchronously.

### Layer 3: Workers

Workers are the execution layer. Each worker has a specific role, tool scope, and model assignment.

| Worker | Role | Tools | Model |
|--------|------|-------|-------|
| Claude Code | Production code, PRs, test writing | Full (Read, Write, Edit, Bash, Glob, Grep, MCP) | Opus 4.8 |
| DeepSeek V4 Pro | Design review, research synthesis | delegate_task subagent | DeepSeek V4 Pro |
| Cron | Scheduled maintenance, monitoring | Shell scripts | N/A |
| MCP servers | Tool access (guild data, memory) | Tool calls | N/A |

**Planned worker profiles (Phase 5f):**

| Profile | Role | Tools | Model |
|---------|------|-------|-------|
| research | Read-only codebase exploration | Read, Glob, Grep, Web search | DeepSeek V4 Flash |
| code-review | PR review, security audit | Read, Glob, Grep, Git diff | Claude Code |
| general | Full development (current default) | Full tools | Claude Code |

## Data Flow

### Feature Development Flow

```
Kevin (Discord)
  │  "Build event cancellation feature"
  ▼
Hermes
  │  1. Decomposes task
  │  2. Runs design review (DeepSeek subagent)
  │  3. Writes scope doc to /tmp/
  │  4. Dispatches to Claude Code via tmux send-keys
  ▼
Claude Code (tmux session)
  │  1. Reads scope doc
  │  2. Reads relevant files
  │  3. Implements changes
  │  4. Runs tests
  │  5. Signals completion at ❯ prompt
  ▼
Hermes
  │  5a. Runs QA gate (checks success criteria)
  │  5b. Verifies git state (commit landed? branch correct?)
  │  6. Reports to Kevin
  │  7. Kevin approves → Hermes pushes branch, opens PR
  │  8. CI runs
  │  9. CI green → Hermes merges PR
  │  10. Pulls main, rebuilds Docker, deploys
  │  11. Posts deploy notification to Discord
  ▼
Kevin (Discord)
      Receives deployment confirmation
```

### Research Flow (planned, Phase 5f)

```
Hermes
  │  "Research how other tools handle cancelled events"
  ▼
delegate_task(profile="research", tools=["Read","Glob","Grep","Web search"])
  │  Isolated subagent with Read-only access
  │  Cannot modify files, cannot run arbitrary commands
  ▼
Hermes
  │  Receives research summary
  │  Injects findings into next task doc
```

## Memory Architecture

AdVanced OS has three memory stores, each serving a different access pattern:

| Store | Type | Access | Best For | Write Frequency |
|-------|------|--------|----------|-----------------|
| Obsidian vault | Graph-linked markdown | Human browse + agent filesystem | Long-term knowledge, decisions, project plans | Daily (human + cron sync) |
| OpenBrain MCP | Vector-semantic | Agent tool call (write/read) | Agent-fast decision retrieval | Per-task (agents) |
| Hermes memory | Key-value | Memory tool injection | Cross-session facts, user preferences | Per-interaction (Hermes) |
| Compound learning file | Flat markdown | Hermes injects into task docs | Cross-session patterns, gotchas | Post-task (Hermes) |

**Key insight:** These stores are complementary, not competing. Obsidian is for human browsing. OpenBrain is for agent-speed retrieval. Hermes memory is for compact cross-session facts. The compound learning file is the Hermes-curated cross-session reference.

## Safety Architecture

The circuit breaker is the most critical safety component. It sits between Kevin and every dispatch:

```
Kevin request
  │
  ┌──▼──┐
  │ CB  │  ← Checks: spend cap, dispatch depth, global stop flag
  └──┬──┘
     │ PASS
  ┌──▼──┐
  │ QA  │  ← After worker finishes: checks success criteria
  └──┬──┘
     │ PASS
  ┌──▼──┐
  │ DEP │  ← Kevin approval required for deploy
  │ LOY │
  └─────┘
```

**Circuit breaker checks:**
1. **Spend cap** — Per-week dollar limit. Hermes stops dispatching when hit. Kevin alerted.
2. **Dispatch depth** — Max 3 chained dispatches from a single request. Kill at 4.
3. **Global stop** — `/stop-hermes` pauses all cron, kills current dispatch, prevents new ones. Flag on disk.
4. **Time cap** — If task exceeds N minutes, checkpoint and ask Kevin to confirm.

## Protocol Decisions

| Protocol | Decision | Rationale |
|----------|----------|-----------|
| MCP | **Primary** — all tool access | Standardized agent→tool protocol. Our MCP servers: ObsoleteBot, OpenBrain |
| A2A (Google) | **Not used** | Designed for multi-runtime peer-to-peer. We have one serial channel. |
| ACP (IBM) | **Not used** | Enterprise use cases. Single-user doesn't need structured task cards. |
| File-based (Hermes) | **Primary** — orchestrator↔worker | Write request → worker picks up → writes response. Deadlock-free. |

## Deployment Architecture

```
┌─────────────────────────────────┐
│         Docker Host             │
│  ┌──────────┐ ┌──────────┐     │
│  │   API    │ │   Bot    │     │
│  │ (Node)   │ │ (Node)   │     │
│  └────┬─────┘ └────┬─────┘     │
│       │            │           │
│  ┌────▼────────────▼─────┐    │
│  │      PostgreSQL       │    │
│  └───────────────────────┘    │
│                                │
│  Hermes runs natively          │
│  (not inside Docker)           │
│  Claude Code runs via tmux     │
│  (not inside Docker)           │
└─────────────────────────────────┘
```

- **Single host, no HA** — alert + back off is the correct failure mode
- **Deploy via:** `git pull → docker compose build + up -d → prisma migrate deploy`
- **Hermes runs alongside** — orchestrates but is not orchestrated itself
