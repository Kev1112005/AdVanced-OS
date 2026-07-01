# Decision: Structured Event Log, Not a Tracing DB

- **Date:** 2026-07-01
- **Status:** Approved
- **Context:** Observability infrastructure for AdVanced OS

## Context

AdVanced OS needs to answer "what happened" — which agent did what, when, and with what result. Options range from a flat event log to a full OpenTelemetry tracing pipeline.

## Options Considered

1. **Structured event log:** Flat log file at `~/.hermes/logs/agent-events.log`. Structured format: `[timestamp] <correlation_id> <event_type> <agent> <detail>`. grepable by any field.
2. **Formal tracing DB:** OpenTelemetry collector + Jaeger/Zipkin backend. Span-based tracing with parent/child relationships.
3. **No observability:** Trust tmux capture-pane output and Claude's self-reporting.

## Chosen Approach

Option 1 — Structured event log. Grepable flat file.

## Rationale

- A tracing DB (Option 2) adds infrastructure: collector daemon, storage backend, query UI. For a single-user system, this is disproportionate to the need. When Kevin asks "what happened yesterday," grep is faster than opening Jaeger.
- Elastic: the flat file can be imported into any query tool later if needed. The structured format survives migration.
- Cheap: ~50 lines of shell wrappers around existing dispatch/notify/monitor functions.
- Option 3 (no observability) was the pre-OS state, and it had the "agents fail silently" problem. The event log is the minimum viable fix.
- The correlation ID (Phase 1b) provides the trace across events. Grep by correlation ID to get the full chain.
- `tail -f ~/.hermes/logs/agent-events.log` provides a live feed for the Mission Control HTML page (Phase 5c stretch).

## Event Types

| Type | Emitted When | Payload |
|------|-------------|---------|
| `dispatch` | Hermes sends task to worker | worker name, task ID, estimated cost |
| `ack` | Worker signals task accepted | worker name, task ID |
| `complete` | Worker signals task done | worker name, task ID, duration |
| `fail` | Worker reports or Hermes detects failure | worker name, task ID, error summary |
| `qa_pass` | QA gate (Phase 5e) criteria met | task ID, criteria checked |
| `qa_fail` | QA gate criteria not met | task ID, failed criteria |
| `circuit_break` | Circuit breaker triggered | reason (spend/dispatch-depth/stop) |
| `deploy_start` | Deploy begins | change summary |
| `deploy_done` | Deploy completes | result (success/rollback) |

## Consequences

- No parent/child span tree. Querying the full trace requires grep by correlation ID and reading chronological events. Sufficient for single-user.
- No query UI. grep + `tail -f` is the interface. If Kevin wants a visual query tool later, the structured format can feed one.
- ~50 lines of shell. Zero infrastructure dependencies.
