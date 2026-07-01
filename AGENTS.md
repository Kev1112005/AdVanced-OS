# AGENTS.md — AdVanced OS

> **What developer agents (Claude Code, Codex, opencode, etc.) need to know before working on this project.**

## Project Identity

AdVanced OS is a **Hermes-based Agentic Operating System**. The orchestrator is Hermes Agent (by Nous Research). Workers include Claude Code, DeepSeek, and cron. The human operator is Kevin. This is NOT an Anthropic project — Claude is one worker among many.

## Core Constraint

**Hermes dispatches via a serial tmux channel, not concurrent RPC.** This means:
- Only one dispatch can be active at a time
- Workers cannot call back into Hermes synchronously (deadlock risk)
- Async request files (`hermes-request`, `hermes-notify`) are the only worker→orchestrator communication
- Design for one serial pipe, not a dispatch bus

## Files You Should Read First

| File | Why |
|------|-----|
| `README.md` | Project overview, key features, architecture diagram |
| `ARCHITECTURE.md` | Detailed architecture, layers, data flow |
| `PLAN.md` | Implementation phases and roadmap |
| `DESIGN_DECISIONS.md` | Why we chose what we chose — prevents re-litigation |
| `DO_NOT_BUILD.md` | Explicit off-limits items — prevents wasted proposals |
| `CONTRIBUTING.md` | How to contribute, commit message format, PR workflow |

## What to Build

1. **Read `PLAN.md` first** — know which phase is active and what's gated behind it
2. **Check `DO_NOT_BUILD.md`** — if the proposed work appears in that table, stop and explain why it's off-limits
3. **Check `DESIGN_DECISIONS.md`** — if the proposed work conflicts with a documented decision, stop and explain the conflict
4. **Read `ARCHITECTURE.md`** — understand where the new code fits in the layer stack
5. **Proceed only if all three checks pass**

## What NOT to Build (Quick Reference)

| Item | Reason |
|------|--------|
| MCP server for Claude→Hermes | Deadlock risk on serial tmux channel |
| Self-learning skill generation | Produces noise Kevin hand-filters anyway |
| A2A protocol between agents | One serial channel, no peers |
| Session checkpointing | Cannot serialize closed CLI working context |
| Formal tracing DB | Correlation ID + grep is sufficient for single-user |
| Cost dashboard | Weekly text summary + structured log is enough |
| AIOS / Agno / LangGraph | In-process frameworks that own the LLM loop |
| Graceful degradation framework | Single host = no HA, alert + back off is correct |
| Deploy Go/No-Go automation | Kevin approves every deploy |
| Self-improvement loop | Compound learning file (5d) is the Hermes-native approach |
| Subagent/profile spawning CLI | Only 2 profiles exist — manual setup is fine |
| Loop self-critique / maker-checker LLM verifier | Duplicates Decisions 006 & 007 — use shell QA gate (5e) + human-curated STATE |

## Code Conventions

- **Language:** Shell scripts (bash) for Hermes integration hooks. Markdown for documentation. No TypeScript/JavaScript — that's the coding worker's domain, not the OS layer.
- **Style:** POSIX-compatible shell where possible. `#!/usr/bin/env bash` for target-specific scripts. Error handling: `set -euo pipefail`.
- **Hermes skills:** YAML frontmatter + Markdown body. One skill file per concern.
- **Worker profiles:** YAML in `docs/worker-profiles/`. One file per profile.
- **Decision records:** Markdown in `docs/decisions/`. One file per decision. Format: context → options considered → chosen approach → consequences.
- **Testing:** ShellCheck for shell scripts. Manual verification described in commit messages.
- **Commits:** Conventional Commits format — `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`. Descriptive body.

## Safety Rules (Critical)

1. **Circuit breaker must exist before any dispatch automation** — Phase 2 before Phase 1a
2. **Global stop flag must persist to disk, not memory** — watchdog restarts would silently un-pause
3. **Cooperative halt** — kill must let the current commit finish before hard-stopping
4. **Depth counter on correlation ID** — prevents runaway dispatch chains across the async file boundary
5. **Kevin is always the top of the architecture** — no autonomous deploy, no autonomous cron mutation, no autonomous spending beyond cap

## Key Contacts

- **Orchestrator:** Hermes (via this repo)
- **Human operator:** Kevin (Discord: kev1112005)
- **Primary coding worker:** Claude Code (Opus 4.8, tmux session)
- **Design reviewer:** DeepSeek V4 Pro (via delegate_task)
- **Memory (human):** Obsidian vault at ~/vaults/kevin/
- **Memory (agent):** OpenBrain MCP, Hermes memory tool

## Registry

| Worker | Role | Tools | Model |
|--------|------|-------|-------|
| (planned) | research | Read, Glob, Grep, Web search | DeepSeek V4 Flash |
| (planned) | code-review | Read, Glob, Grep, Git diff | Claude Code |
| (current) | general | Full tools | Claude Code |
