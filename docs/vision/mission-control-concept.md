# Mission Control Concept

> A visual dashboard for AdVanced OS. Stretch goal (Phase 5c). Not building yet.

## Why a Dashboard?

The terminal-native interface (Discord CLI + structured event log) covers all information needs — "what's running," "what happened yesterday," "how much did it cost." A dashboard adds one thing: **at-a-glance awareness**. You don't need to ask. You look.

## When to Build

Build Phase 5c (Mission Control HTML page) only if:
- Kevin asks "I wish I could see what all agents are doing on one screen"
- The `hermes status` command (Phase 5b) becomes a frequently-used crutch — Kevin checks it multiple times per session
- Kevin wants to share system status with someone who doesn't use Discord (unlikely in single-user, but possible for demos)

## Concept: Terminal View

Minimum viable dashboard: a terminal dashboard served via `hermes dashboard` that uses ANSI escape codes to render a live-updating view in the terminal. No web server. No HTML. Just:

```
┌─────────────────────────────────────────────────────────────┐
│  AdVanced OS  │  Circuit Breaker: OK  │  Spend: 43% of cap  │
├─────────────────────────────────────────────────────────────┤
│  WORKERS                      STATUS        DURATION       │
│  claude-obsoletebot           IDLE (❯)      12m             │
│  claude-remote-control        ACTIVE        3m (task#42)   │
│  cron: watchdog               OK            last: 4m ago   │
│  cron: health                 OK            last: 2m ago   │
│  cron: vault-sync             OK            last: 1m ago   │
├─────────────────────────────────────────────────────────────┤
│  RECENT EVENTS                                              │
│  14:32:12  dispatch  claude-code  task#42  fix/cancelled    │
│  14:32:15  ack       claude-code  task#42                   │
│  14:35:20  complete  claude-code  task#42                   │
│  14:35:21  qa_pass   hermes       task#42  3/3 criteria met │
├─────────────────────────────────────────────────────────────┤
│  hermes> _                                                  │
└─────────────────────────────────────────────────────────────┘
```

This is terminal-native, requires no web server, and provides at-a-glance awareness. Phase 5c covers this if Phase 5b (status snapshot) shows it's needed.

## Concept: HTML Dashboard (Stretch)

If Kevin wants a browser tab, the HTML dashboard is a single static page served by a simple HTTP server. No React. No build step. Inline CSS and JS polling a JSON endpoint:

**Data source:** `~/.hermes/status/current.json` (from Phase 5b) + `~/.hermes/logs/agent-events.log` (from Phase 5a)

**Layout:**
- Top bar: system health (circuit breaker OK/warning/critical, spend-to-cap meter)
- Worker panel: grid of worker cards, each showing name, status (active/idle/error), current task, duration
- Event feed: scrolling list of recent events with correlation ID, filterable by worker
- Cost meter: weekly spend bar with cap line, trend arrow vs last week

**Technical approach:**
- Python's built-in HTTP server or a 10-line Express app
- Single HTML file with inline CSS and JS
- Polls `/api/status` (reads current.json) and `/api/events` (tails agent-events.log) every 5 seconds
- No database. No build step. No dependencies.
- ~200 lines of code total

## What We Won't Build

- **Real-time WebSocket updates.** Polling every 5 seconds is sufficient for at-a-glance awareness. WebSockets add complexity for negligible benefit.
- **Persistent storage.** The dashboard reads from files that already exist (5a, 5b). It doesn't write anything.
- **Authentication.** Single-user, local-only. If shared, a reverse proxy handles auth.
- **Mobile app.** The Discord CLI is the mobile interface. The dashboard is for desktop.
- **Customizable views.** One layout. Kevin doesn't customize his Discord CLI either.
