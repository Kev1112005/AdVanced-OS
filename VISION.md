# AdVanced OS — Vision

> Where this is going. Not a commitment to build everything here — a direction.

## The Long Arc

AdVanced OS starts as a terminal-native orchestrator with Discord as its interface. Kevin talks to Hermes, Hermes dispatches workers, workers execute, Hermes reports back. This is the minimum viable form.

The long arc moves through three stages:

**Stage 1: Terminal-Native (current → Phase 4)**
- Kevin interface: Discord CLI
- Hermes orchestrates via tmux dispatch + cron
- Observability: structured event log + correlation ID grep
- Safety: circuit breaker with spend cap + global stop
- Workers: Claude Code (general), DeepSeek (research), cron (scheduled)
- Memory: Obsidian vault + OpenBrain + Hermes memory

**Stage 2: Observable (Phase 5a-5e)**
- Hermes emits structured events at every boundary
- `hermes status` answers "what's running now" on Discord
- Compound learning file allows Hermes to inject cross-session patterns into task docs
- QA gate catches delivery failures before Kevin sees them
- Still terminal-native, but the information is structured and queryable

**Stage 3: Visible (Phase 5c + beyond — stretch)**
- Mission Control HTML page shows all agents, tasks, and status in one view
- Chronological event viewer with correlation ID filtering
- Spend trends over time
- Worker health metrics
- Not a replacement for terminal-native operation — an addition for at-a-glance awareness

## What Success Looks Like

**Kevin's experience, post-Stage 2:**

```
Kevin: Ship the event cancellation fix
Hermes: Checking circuit breaker... PASS. Dispatching to Claude.
        Event: dispatch → claude-code → task#42 → build:fix/event-cancellation
  [3 min later]
Hermes: Claude completed task#42.
        QA gate: checking commit landed... ✓
        QA gate: checking tests pass... ✓
        QA gate: checking files changed... ✓
        All checks passed. Summary:
          - Fixed CANCELLED status filter in event queries
          - Updated RSVP embed to show cancelled state
          - Added test coverage for cancelled event edge cases
        Push branch? Approve deploy?
Kevin: Deploy
Hermes: Branch pushed. CI running...
  [2 min later]
Hermes: CI green. Merging PR #417.
        Pulling main. Rebuilding. Deploying.
        Deploy complete. Health check: PASS.
        Weekly spend: $5.82 (43% of cap)
```

The key properties:
- Kevin never reads raw terminal output to understand what happened
- Every agent action is logged, traceable, and cost-tracked
- Safety checks run before every dispatch and after every completion
- Mistakes are caught before Kevin sees the result, not after
- Kevin's approval is fast because the summary is clean

## What We Are Not Building

- **Not an agent framework.** LangGraph, CrewAI, AIOS — these own the LLM loop. We don't. Hermes orchestrates workers, not LLM calls.
- **Not a coding agent.** Claude Code, Codex, opencode — these write code. We orchestrate them. Hermes does not write production code.
- **Not a SaaS platform.** Single-user. One Docker host. Kevin is the only operator.
- **Not autonomous.** Every deploy needs Kevin's approval. The circuit breaker prevents runaway behavior.
- **Not a replacement for existing tools.** Obsidian stays. Discord stays. tmux stays. Hermes orchestrates them.
- **Not Claude-centric.** Claude is a worker. DeepSeek is a worker. Cron is a worker. Hermes is the orchestrator.

## The Bet, Restated

The bet is that **orchestration infrastructure compounds faster than worker intelligence.** A smarter worker running without coordination infrastructure is still a single point of failure. A coordinated system of average workers — with shared memory, structured handoffs, and safety rails — outperforms a single brilliant worker every time.

This is the supervising pattern: a coordinator delegates non-overlapping tasks to specialists and synthesizes their independent results. Hermes is the coordinator. Workers are the specialists. Kevin is the highest authority.

The name "AdVanced OS" reflects this: not "advanced" as in smarter agents, but **"Ad-Vanced"** — a system built by adding layers of orchestration, memory, and safety on top of whatever workers happen to be the best available at any given time. The workers change. The OS stays.
