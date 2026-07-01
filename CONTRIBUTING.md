# AdVanced OS — Contributing Guidelines

> These guidelines are for developer agents (Claude Code, Codex, opencode, etc.) contributing to this repository. Hermes and Kevin delegate tasks here. Follow these rules.

## Before You Start

1. **Read `PLAN.md`** — know which phase is active and what's gated behind it
2. **Check `DO_NOT_BUILD.md`** — if your proposed work is in that table, stop and report why
3. **Check `DESIGN_DECISIONS.md`** — if your proposed work conflicts with a documented decision, stop and report the conflict
4. **Read `ARCHITECTURE.md`** — understand where your change fits in the layer stack

## What to Build

This repository contains the **Agentic Operating System layer** — the orchestration, safety, observability, and dispatch infrastructure. It does NOT contain production application code.

**Build:**
- Shell scripts for Hermes integration hooks (`~/.hermes/scripts/`)
- Hermes skill definitions
- Worker profile definitions (YAML)
- Documentation and reference material
- Decision records

**Do NOT build:**
- TypeScript/JavaScript application code (that's the coding worker's domain, dispatched via Hermes to Claude Code)
- Full-featured web dashboards (unless explicitly requested as Phase 5c)
- Database schemas or API routes (those belong in the application repos, not the OS repo)

## Code Conventions

### Shell Scripts
- POSIX-compatible shell where possible
- `#!/usr/bin/env bash` for target-specific scripts
- Error handling: `set -euo pipefail`
- Validate with ShellCheck before committing

### Hermes Skills
- YAML frontmatter + Markdown body
- One skill file per concern
- Place in the appropriate Hermes skill category directory

### Worker Profiles
- YAML format
- One file per profile in `docs/worker-profiles/`
- Specify: name, role, tools allowed, model assignment, max turns, output format

### Decision Records
- Markdown in `docs/decisions/`
- One file per decision
- Format: Context → Options Considered → Chosen Approach → Rationale → Consequences

## Commit Messages

Use Conventional Commits format:

```
<type>: <short description>

<body with details and rationale>
```

Types: `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `test:`

**Bad:** "Update stuff"  
**Good:** `feat: add structured event log for dispatch boundaries (Phase 5a)`

## PR Workflow

1. Hermes dispatches a task to a worker with specific scope
2. Worker implements in a feature branch
3. Worker opens PR against `main`
4. CI runs (lint ShellCheck, markdown link check)
5. Hermes reviews, merges on green
6. Cleanup: remove feature worktree, prune remote branch

## Safety Rules

- **Never** push directly to `main` (except initial scaffolding)
- **Never** build Phase 1a (async shell bridge) before Phase 2 (circuit breaker)
- **Never** implement items in `DO_NOT_BUILD.md` without a decision record explaining why the exception is justified
- **Always** update `PLAN.md` status when a phase completes
- **Always** add a decision record when choosing an approach with meaningful trade-offs

## Getting Help

If you encounter something not documented here, ask in the PR or check the existing documentation in `docs/`. If it's a design question, add a decision record rather than asking Kevin — decisions should be documented, not ephemeral.
