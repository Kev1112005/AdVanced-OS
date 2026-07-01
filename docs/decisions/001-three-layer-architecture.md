# Decision: Three-Layer Architecture

- **Date:** 2026-07-01
- **Status:** Approved
- **Context:** Initial architecture design for AdVanced OS

## Context

The system needed an architecture that accommodates one hard constraint: Claude Code operates via a single serial tmux session, not a concurrent RPC service. Most agent frameworks (AIOS, Agno, LangGraph) assume they own the LLM loop and manage agents in-process.

## Options Considered

1. **Three-layer (Orchestration → Dispatch → Workers):** Hermes as orchestrator, file-based tmux dispatch, independent workers. Kevin at top.
2. **A2A protocol:** Google's Agent-to-Agent protocol for peer-to-peer agent communication.
3. **MCP server for Claude→Hermes:** Bidirectional MCP bridge allowing Claude to call Hermes features.
4. **AIOS/LangGraph/Agno:** In-process agent frameworks that manage the LLM loop.

## Chosen Approach

Option 1 — Three-layer architecture. Hermes orchestrates via serial dispatch to workers. Async request files for worker→orchestrator communication.

## Rationale

- A2A assumes multiple agent runtimes that need peer-to-peer discovery. We have one tmux channel.
- MCP bridge has a concrete deadlock risk: Hermes blocks on tmux waiting for Claude, Claude calls back into Hermes via MCP → both hang.
- AIOS/LangGraph/Agno own the LLM loop. Claude Code is a closed CLI — we cannot wrap it inside them. Adopting them means either (a) wrapping Claude as a tool (worse than direct tmux), or (b) replacing Claude entirely.
- Three-layer is simple, deadlock-free, and each layer has clear boundaries. It accommodates the serial channel constraint without fighting it.

## Consequences

- Workers cannot call back into Hermes synchronously. Async request files (`hermes-request`, `hermes-notify`) are the only worker→orchestrator communication path.
- Only one dispatch at a time through the tmux channel. Parallel fan-out requires `delegate_task` subagents instead.
- No concurrent RPC, no peer-to-peer agent communication. This is by design.
