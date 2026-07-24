# Decision 008: Provider Registry and GUI Control Surface

## Context

Mission Control began as an awareness-only page with agent sessions hard-coded in the HTTP server, snapshot script, and browser. The operating model now includes Codex, Claude Code, and Hermes agents, and the operator needs to issue structured tasks and perform explicit safety actions from the same dashboard used for monitoring.

The serial tmux constraint still applies: provider diversity does not turn Hermes into a concurrent RPC bus.

## Options Considered

1. Keep agent definitions hard-coded in each component.
2. Introduce a database-backed agent service and remote execution API.
3. Add a file-backed provider registry and keep the durable request queue as the dispatch boundary.

## Chosen Approach

Use `config/providers.json` as the source of truth for providers, registered agents, capabilities, tmux session names, and restart commands.

- The dashboard reads the registry through `GET /api/providers`.
- The status snapshot iterates the registry instead of maintaining a second roster.
- Structured orders are validated against the registry and written to the existing durable request directory.
- The serial dispatch consumer remains the only component that injects tasks into worker sessions.
- Pause flags and the global stop remain disk-backed.
- Interrupt, restart, deployment approval, and denial require explicit operator actions.
- Local tmux is the initial transport. A future transport may be added behind the registry without changing the UI or order schema.

Mission Control is now both an awareness and control surface for a single trusted operator. Discord remains a complementary remote interface, not the sole control path.

## Rationale

The registry removes duplicated agent knowledge while preserving the safety architecture already proven by the project. A database or general agent protocol would be disproportionate for a single-host system and would invite incorrect concurrency assumptions. A durable queue gives every provider the same observable task boundary.

## Consequences

- Adding an agent requires one registry entry instead of coordinated edits across the UI and snapshot script.
- Provider status and task ownership can be rendered consistently.
- Restart commands are trusted local configuration and must be reviewed like executable code.
- A paused agent retains queued orders; resuming it allows the serial consumer to continue.
- Interrupting a live session may leave a dirty working tree, so the UI requires confirmation and records the event.
- Remote workers remain an adapter concern. They are not implied to be connected merely because their provider is registered.
