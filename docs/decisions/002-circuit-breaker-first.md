# Decision: Circuit Breaker Before Accelerator

- **Date:** 2026-07-01
- **Status:** Approved
- **Context:** Implementation order for AdVanced OS

## Context

Phase 1a (async shell bridge) introduces `hermes-request research` — a command that triggers Hermes to dispatch research tasks to subagents. This creates a feedback loop: Kevin says X → Hermes dispatches Claude → Claude calls `hermes-request research` → Hermes dispatches DeepSeek → DeepSeek returns → Hermes reports back to Claude → Claude continues. Without bounds, this chain can repeat indefinitely, spending money and modifying state with no upper limit.

## Options Considered

1. **Circuit breaker first:** Spend cap, dispatch-depth limit, global stop on disk before any dispatch automation.
2. **Build all at once:** Ship the bridge and breaker together in one phase.
3. **No circuit breaker:** Trust the system not to loop. Add safety measures as needed.

## Chosen Approach

Option 1 — Circuit breaker first. Phase 2 before Phase 1a. The accelerator must never exist without brakes.

## Rationale

- Option 2 assumes simultaneous delivery of two features. In practice, one ships first. If the bridge ships without the breaker, a runaway loop is possible between ship and breaker delivery.
- Option 3 ignores the primary failure mode of every autonomous agent system: runaway spend/state with no kill switch.
- The circuit breaker is ~20 lines of shell + config. Cheap to build. Expensive to miss.
- Claude Code's own review (Opus 4.8) confirmed this ordering: "Moving Phase 2 before Phase 1a so the accelerator never exists without brakes."

## Specific Checks

The circuit breaker must enforce four things before every dispatch:

1. **Spend cap:** Per-week dollar limit. Hard stop when hit.
2. **Dispatch depth:** Max 3 chained dispatches from a single user request. Kill at 4.
3. **Global stop:** `/stop-hermes` command. Flag on disk (not memory). Persists across Hermes restarts.
4. **Time cap:** If task exceeds N minutes, checkpoint and ask Kevin to confirm continue.

## Consequences

- Phase 1a is delayed until Phase 2 ships. Day 2 instead of Day 1.
- Cost logging (Phase 1c) and correlation ID (Phase 1b) are harmless and ship alongside the breaker on Day 1.
- The circuit breaker adds ~half a day to the overall timeline.
