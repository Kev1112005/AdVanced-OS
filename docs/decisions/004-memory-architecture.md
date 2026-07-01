# Decision: Three Complementary Memory Stores

- **Date:** 2026-07-01
- **Status:** Approved
- **Context:** Memory architecture for cross-session persistence

## Context

AdVanced OS needs memory that persists across sessions. Agents must remember past decisions, project context, and user preferences. Different agents access memory differently — some need fast semantic retrieval (agents), others need graph-based browsing (humans), others need compact fact injection (orchestrator).

## Options Considered

1. **Three complementary stores:** Obsidian vault (graph-linked, human-readable) + OpenBrain MCP (vector-searchable, agent-fast) + Hermes memory tool (compact cross-session facts).
2. **Single store:** Everything in one system — Obsidian, OpenBrain, or a database.
3. **Two stores:** Obsidian + Hermes memory, skip OpenBrain. Or OpenBrain + Hermes memory, skip Obsidian.

## Chosen Approach

Option 1 — Three complementary stores, each serving a different access pattern.

## Rationale for Three Stores

**Obsidian vault:**
- Graph of linked markdown documents. Human-readable by design.
- Best for: long-term knowledge, project plans, decision records, reference material.
- Agent access: filesystem direct (slow but thorough).
- Write pattern: daily (human writing + cron git sync).
- Cannot be replaced by OpenBrain because OpenBrain has no graph/link structure or human browsing interface.

**OpenBrain MCP:**
- Vector-semantic retrieval. Agent-speed reads and writes.
- Best for: discrete decision log, agent-fast retrieval of specific facts.
- Agent access: MCP tool call (fast, structured).
- Write pattern: per-task (agents log decisions as they work).
- Cannot be replaced by Obsidian because Obsidian has no semantic search API.

**Hermes memory tool:**
- Compact key-value store injected into every turn.
- Best for: cross-session facts, user preferences, environment details.
- Agent access: injected automatically by Hermes.
- Write pattern: per-interaction (Hermes writes corrections).
- Cannot be replaced by either because neither is compact enough for injection into every system prompt.

## Consequences

- Three systems to maintain instead of one. Acceptable because each serves a distinct access pattern that the others cannot replace.
- Risk of fragmentation: a fact exists in one store but not another. Mitigated by clear write-pattern rules: decisions go to Obsidian + OpenBrain, preferences go to Hermes memory, reference goes to Obsidian only.
- The compound learning file (Phase 5d) is technically a fourth store, but it's a single flat file that Hermes reads before dispatch — not a general-purpose memory system. It sits outside this decision.
