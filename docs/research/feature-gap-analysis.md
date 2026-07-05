# Feature Gap Analysis — AdVanced OS

> Research briefing compiled by Ezekiel, Chief Librarian.
> Date: 2026-07-05
> Status: Findings for review by Kevin

---

## 1. Feature Gaps — What AdVanced OS Is Missing

### 1.1 Alerting Infrastructure

**Status:** Absent
**Priority:** HIGH

The system has no mechanism to push critical notifications to Kevin outside the dispatch cycle. Currently the system observes everything reliably (event log, cost log, status snapshot) but cannot call for help. If a cron job fails repeatedly, an agent hangs past its time cap, or disk space runs low, Kevin must be actively polling the GUI or waiting for a dispatch result to discover the problem.

The circuit breaker enforces a hard spend cap ($20/week) but provides no intermediate alerting. Kevin discovers he is approaching the cap only when a dispatch is **blocked** — not when he crosses 50%, 75%, or 90%.

**What exists:** The circuit breaker config references `alerts.channel: "discord:#officers"` (line 22 of `config/circuit-breaker.yaml`) but no alert dispatch code has been written.

**What would close the gap:**
- A Hermes helper that can push Discord DMs or channel messages outside the dispatch cycle
- Trigger events: circuit breaker at configurable thresholds (50%/75%/90% spend), cron job N-consecutive-failures, agent session death, global stop flag set by a watchdog rather than by Kevin
- Implementation: ~2-3 hours. A shell script that uses Hermes Agent's Discord delivery channel to push notifications. Configurable thresholds in the circuit-breaker.yaml.

**Sources:**

- `config/circuit-breaker.yaml:22` — alert channel defined, no implementation
- `scripts/agent-event.sh:36-51` — events logged to file only, no routing
- `scripts/circuit-breaker.sh:90-94` — binary PASS/FAIL spend check, no warning thresholds
- `PLAN.md:88` — cost alert at 80% cap mentioned but not scoped

---

### 1.2 Task Prioritisation in Dispatch Queue

**Status:** Does not exist
**Priority:** MEDIUM

`dispatch-consumer.sh` reads queued request files from `~/.hermes/requests/` and processes them in filesystem iteration order — not by priority. The request JSON schema already includes a `priority` field (written by `serve.py`), but no code reads or honours it.

This means a critical bugfix queued after a routine maintenance task waits for the earlier task to finish. In a serial dispatch system, ordering matters.

**What would close the gap:**
- Sort `$REQ_DIR/*.json` by priority field before iterating
- Define a natural order: high > normal > low
- Options: drain high first, then normal, then low. Or interleave (2 high : 1 normal : 1 low).
- Implementation: ~15 minutes. One sort-like call before the `for req_file in` loop in `dispatch-consumer.sh:54`.

**Sources:**

- `scripts/dispatch-consumer.sh:50-54` — iterates files with glob, no sort
- `server/serve.py:148-158` — priority field written but never read downstream
- `server/serve.py:153` — `create_dispatch()` sets `priority: data.get("priority", "normal")`

---

### 1.3 Retry with Backoff for Transient Dispatch Failures

**Status:** Does not exist
**Priority:** MEDIUM

If a dispatch fails because the target agent is mid-thought or the tmux session is temporarily unavailable, `dispatch-consumer.sh` logs the failure and moves to the next request. No retry mechanism exists.

The agent-running check (`grep -qE 'Spinning|Baking|Hatching|...'`) will find the agent busy on the next cron poll (every 5 minutes by default), but a transient "busy" state could last 30 seconds and would be better served by a short backoff than a 5-minute delay.

**What would close the gap:**
- Track retry count per request in a sidecar metadata file or a retry counter embedded in the request filename
- Backoff: retry at 30s, 60s, 120s, then fail permanently
- On 4th failure: escalate to Kevin via the alerting system (see 1.1)
- Implementation: ~30 minutes. Add a `.retries` counter to `dispatch-consumer.sh`.

**Sources:**

- `scripts/dispatch-consumer.sh:73-76` — `continue` on busy agent, no retry
- `scripts/dispatch-consumer.sh:79-84` — single attempt on send failure, then `continue`
- `scripts/agent-event.sh:50` — failure logged but not actionable

---

### 1.4 Agent Heartbeat / Liveness Monitoring

**Status:** Passive only
**Priority:** MEDIUM

The status snapshot (`status-snapshot.sh`) detects active/idle agents via tmux pane capture — a passive check. Roster agents with no live tmux session are reported as `offline`. There is no active liveness probe: no mechanism to verify an agent session is still responsive beyond "the tmux session exists."

If a session is wedged (tmux pane shows stale output, the agent is unresponsive but hasn't exited), the dashboard reports it as `idle`, not as `stuck`. Kevin has no way to distinguish "agent finished and waiting" from "agent crashed silently."

**What would close the gap:**
- Send a lightweight ping to each agent session on a configurable interval (e.g., every 2 minutes)
- For tmux-based agents: send a non-destructive command and check for response
- If N consecutive pings go unanswered: mark as `stuck` on the dashboard, log a `circuit_break` event, and push an alert (see 1.1)
- Implementation: ~1-2 hours. Extend `status-snapshot.sh` or create a `heartbeat-check.sh`.

**Sources:**

- `scripts/status-snapshot.sh:17-40` — passive detection via tmux session list + pane capture
- `server/serve.py:109-131` — same logic duplicated in Python for the `/api/agent/session` endpoint
- `scripts/dispatch-consumer.sh:73-76` — discovers unresponsive agents only at dispatch time

---

### 1.5 Wall-Clock Task Duration Tracking

**Status:** Does not exist
**Priority:** LOW

The cost log (`cost-log.sh`) tracks spend per task (input tokens, output tokens, cache hits, cost USD) but records no duration column. There is no data to answer "which tasks take the longest," "is dispatch time trending up," or "what is the average wall-clock time per task type."

Without duration data, the time cap in the circuit breaker (`max_minutes: 30`) has no feedback loop — Kevin cannot tune it based on historical evidence. The time cap is a static value in YAML rather than a data-informed policy.

**What would close the gap:**
- Add a `duration_seconds` column to the cost log CSV format
- Calculate at `cost-log.sh log` time by capturing start time from the correlation ID timestamp (or from an env var set at dispatch) and computing elapsed seconds
- Display average/median/max task duration in the GUI cost panel
- Implementation: ~30 minutes. New column in the CSV header + one `date +%s` calculation.

**Sources:**

- `scripts/cost-log.sh:8` — header: `timestamp,correlation_id,model,input_tokens,output_tokens,cache_read,cache_write,cost_usd,task`
- `config/circuit-breaker.yaml:14` — `max_minutes: 30`, no historical data to tune against

---

### 1.6 Historical Views in Mission Control GUI

**Status:** Does not exist
**Priority:** LOW

The Mission Control dashboard shows current-state data only: active workers, recent events, this-week cost, cron job last-run status. There are no historical views:
- Cost over time (last 4 weeks, daily breakdown)
- Event failure rate trend (last 7 days, by agent)
- Task duration trend (last 30 days, by worker profile)
- Spend rate change vs. last week

The data to build these views already exists in the cost log (CSV, has timestamps) and event log (pipe-delimited, has timestamps). The gap is a storage/aggregation layer and a UI to render it.

**What would close the gap:**
- Add `GET /api/cost/history?period=4w` endpoint in `serve.py` that reads the entire cost log and aggregates by day
- Add `GET /api/events/trend?period=7d` endpoint for failure rate per day per agent
- Add a `<canvas>` chart (inline, no library) or a small table-based trend view in the dashboard HTML
- Implementation: ~2 hours. Python stdlib CSV parsing + simple JSON response + 100 lines of JS for the chart.

**Sources:**

- `server/serve.py:65-91` — `cost_summary()` reads full log but only returns weekly aggregate
- `server/serve.py:48-63` — `read_events()` returns only `N` most recent events, no aggregation
- `public/index.html:276-303` — cost panel shows current week only
- `public/index.html:145-160` — no historical panel present

---

### 1.7 Deploy Risk Classification

**Status:** Specified but not implemented
**Priority:** LOW

Phase 4 (Discord approval UX) plans to show a deploy risk summary — schema changes, new dependencies, config modifications — before asking Kevin to approve. No mechanism to detect these risk factors has been specified or implemented.

Without automated detection, the risk summary is either:
- Manually classified by Kevin (defeating the automation purpose)
- Absent entirely (deploy notifications say "PR #N merged" without risk context)

**What would close the gap:**
- After the QA gate (Phase 5e) verifies commit landed, run detection scripts:
  - Schema change: grep for `prisma migrate` / `CREATE TABLE` / `ALTER TABLE` in the diff
  - New dependency: grep for added entries in `package.json`, `requirements.txt`, `go.mod`
  - Config change: grep for changes in `.env`, `docker-compose.yml`, `config/`
- Output as structured JSON embedded in the deploy notification
- Implementation: ~1 hour. Three grep-based shell scripts called after the QA gate.

**Sources:**

- `PLAN.md:83-88` — Phase 4 aspirational fields: "risk summary (schema change? new dep? config?)"
- No implementation path exists in the codebase or further documentation

---

### 1.8 Prompt Library / Task Template System

**Status:** Does not exist
**Priority:** STRETCH

Each dispatch receives a fresh task document written by Hermes from Kevin's description. There is no reusable library of common task patterns. If Kevin dispatches the same type of task twice ("add test coverage for X," "fix a bug in Y," "audit dependency Z"), the task document is written from scratch each time.

A template system would:
- Accelerate task formulation (pick "Bug Fix" template, fill in the blank)
- Enforce consistency across dispatches of the same type
- Capture conventions that are currently only in the compound learning file (Phase 5d)

**What would close the gap:**
- A `docs/task-templates/` directory with markdown templates for common task types
- The template would include placeholders (e.g., `{{file_path}}`, `{{bug_description}}`)
- Hermes would perform variable substitution before dispatching
- The dashboard dispatch textarea could include a template dropdown
- Implementation: ~1-2 hours for the template files + variable substitution logic.

**Note:** This overlaps with the compound learning file (Phase 5d). The compound learning file captures cross-session *patterns* (gotchas, conventions). A task template library captures cross-session *task structures* (repeatable outlines). They are complementary.

**Landscape reference:** Mihir Modi's Agentic OS includes a prompt library feature. (See `docs/landscape/README.md:48-49`.)

---

### 1.9 Circuit Breaker Alert Thresholds

**Status:** Does not exist (specifically: thresholds below the hard cap)
**Priority:** MEDIUM

The circuit breaker enforces a single hard spend cap ($20/week). When the weekly total reaches or exceeds the cap, the circuit breaker trips and blocks all dispatches. There are no intermediate warning thresholds.

A user who burns through $19 in a single Monday morning task has no alert until the next task is **blocked** — at which point Kevin must intervene before the system can continue.

**What would close the gap:**
- Add configurable warning thresholds in `circuit-breaker.yaml`:
  ```yaml
  spend_cap:
    weekly_usd: 20.0
    warn_at_pct: 50    # Log event + optional push alert
    alert_at_pct: 75   # Push alert to Kevin
    critical_at_pct: 90 # Push alert + ask Kevin to confirm continue
  ```
- Implement in `circuit-breaker.sh`: after the weekly spend is calculated (line 90), check against each threshold and emit events/alerts as configured
- Implementation: ~30 minutes. Add 3 comparisons to the existing spend calculation.

**Sources:**

- `scripts/circuit-breaker.sh:90-94` — single `if (spend >= cap) then FAIL`
- `config/circuit-breaker.yaml:5-7` — no threshold fields

---

### 1.10 Circadian Operation Profiles

**Status:** Does not exist
**Priority:** STRETCH

The circuit breaker has a single spend cap ($20/week) for all hours of all days. There is no concept of:
- Reduced tolerance during off-hours (reduce cap at night when Kevin is asleep)
- Increased allowance during known high-activity windows
- Different depth limits during maintenance windows

This could prevent scenarios where the system burns through 80% of the weekly budget during a single exploratory session at 2 AM, leaving insufficient budget for planned work later in the week.

**What would close the gap:**
- Add a schedule block to `circuit-breaker.yaml`:
  ```yaml
  schedule:
    - hours: "09:00-17:00"    # Business hours
      spend_cap_multiplier: 1.0
      depth_multiplier: 1.0
    - hours: "17:00-23:00"    # Evening
      spend_cap_multiplier: 0.5
      depth_multiplier: 0.66
    - hours: "23:00-09:00"    # Overnight
      spend_cap_multiplier: 0.25
      depth_multiplier: 0.33
  ```
- Apply multipliers to the static caps at circuit breaker check time
- Implementation: ~1 hour. Hour-of-day check + multiplier logic in `circuit-breaker.sh`.

**Sources:**

- `config/circuit-breaker.yaml:5-7` — single `weekly_usd` value
- `scripts/circuit-breaker.sh:67-71` — config loaded as flat values, no temporal logic

---

## 2. Cross-Agent Communication

### Current Architecture

AdVanced OS has a strictly directional architecture for agent communication:

```
┌───────────────────┐       ┌─────────────────────────────┐
│    Hermes         │──────→│  dispatch-consumer.sh        │
│  (Orchestrator)   │       │  (~/.hermes/requests/*.json) │
│                   │       │  ────────────────────────── │
│                   │       │  Targets: claude-belial,     │
│                   │       │  claude-obsoletebot, ezekiel │
└───────┬───────────┘       └─────────────────────────────┘
        │                                                       
        │  delegate_task()                                       
        │  (subagent — returns to caller when done)              
        │                                                       
┌───────▼───────────┐       ┌─────────────────────────────┐
│  Subagents        │       │  Phase 1a (planned):        │
│  (research,       │       │  hermes-request <type>      │
│   code-review)    │──────→│  hermes-notify <message>    │
│                   │       │  (async file bridge)        │
└───────────────────┘       └─────────────────────────────┘
```

### How Agents Communicate Today

**Hermes → Worker (dispatch):**
- Writes a request JSON to `~/.hermes/requests/<uuid>.json`
- `dispatch-consumer.sh` (run by cron every ~1-5 minutes) picks it up, checks the circuit breaker, and sends the task to the target agent's tmux session

**Worker → Hermes (subagents via delegate_task):**
- Ezekiel, when dispatched as a subagent via `delegate_task`, runs in an isolated Hermes session and returns results directly to the caller when finished
- This is synchronous from the caller's perspective — the caller waits for the subagent to complete

**Worker → Hermes (standalone Ezekiel session):**
- Ezekiel runs in its own tmux session (`hermes -p ezekiel --yolo`)
- When dispatched via `dispatch-consumer.sh`, Ezekiel processes the task and writes its response to the tmux buffer
- Hermes reads the response via `tmux capture-pane -t ezekiel -p`
- Ezekiel has no way to initiate communication back to the orchestrator — it can only respond to tasks it receives

### The Gap: Worker-Initiated Communication (Phase 1a)

The architecture defines Phase 1a — the async shell bridge — as the mechanism for worker-initiated communication:

1. **`hermes-request <type> "<payload>"`** — Worker writes a request to `/tmp/hermes-requests/<uuid>.json` and returns immediately. Types: `research`, `notify`, `log`. Hermes picks up the request on its next cron cycle and acts on it.

2. **`hermes-notify "<message>"`** — Fire-and-forget. Writes to a file Hermes surfaces to Kevin.

**This is Phase 1a in PLAN.md, lines 92-95.** It is planned and gated behind Phase 2 (circuit breaker), which is now implemented. This means Phase 1a is **ready to build**.

### What Cross-Agent Communication Would Look Like After Phase 1a

**Ezekiel → Hermes:**
1. Ezekiel finishes research and wants to submit findings
2. Calls `hermes-notify "Research on X complete. Findings in ~/research-output.md"`
3. Hermes reads the notify file, dispatches the finding to Kevin

**Ezekiel → Azrael (Hermes):**
- "Azrael" was the previous name for the Hermes orchestrator profile. It was removed from the dashboard in commit `cbbc893` ("orchestrator, not a worker"). The *concept* of Azrael as the orchestrator persists — it is Hermes itself.
- Ezekiel → Hermes communication is the same as Ezekiel → Azrael: the async file bridge.
- Hermes (Azrael) → Ezekiel communication is the existing dispatch consumer path.

**What is NOT needed:**
- MCP server for Claude→Hermes (DO_NOT_BUILD — deadlock risk)
- A2A protocol (not applicable — one serial channel)
- Bidirectional tmux bridge (would require concurrent RPC, which the architecture explicitly avoids)

**To implement Phase 1a, build:**
- `scripts/hermes-request.sh` — writes a JSON file to `~/.hermes/requests/` (reusing the existing dispatch consumer infrastructure) with a `type` field that the consumer routes differently (to Kevin's inbox rather than to a tmux session)
- `scripts/hermes-notify.sh` — appends to `~/.hermes/notifications.log` that Hermes tails and surfaces to Kevin
- A file watcher that triggers Hermes to process notifications (or piggyback on the existing cron-based dispatch consumer)
- Implementation: ~2-3 hours (estimated in PLAN.md)

### Sources

- `PLAN.md:92-95` — Phase 1a specification
- `ARCHITECTURE.md:48-55` — dispatch methods table, async bridge row
- `PRINCIPLES.md:63-64` — async request files are the only worker→orchestrator communication
- `DO_NOT_BUILD.md:7` — MCP server for Claude→Hermes explicitly rejected
- `scripts/dispatch-consumer.sh` — existing Hermes → worker infrastructure that the async bridge would extend
- Git log: `cbbc893` — Azrael removed from dashboard as "orchestrator, not a worker"

---

## 3. Agent Generation — Adding New Workers

### Current State

AdVanced OS currently has **3 registered workers**:

| Worker | Role | Session | Status |
|--------|------|---------|--------|
| Belial (claude-belial) | General coding worker | tmux | Active |
| ObsoleteBot (claude-obsoletebot) | Bot coding worker | tmux | Active |
| Ezekiel (ezekiel) | Research worker | tmux (on demand) | Active |

A **research** worker profile is planned (Phase 5f, stretch) but not implemented. A **code-review** worker profile is also planned.

### Current Registration Method (Manual)

Adding a new agent today requires touching **5 files**:

1. **`docs/worker-profiles/<name>.md`** — Worker profile definition (YAML frontmatter + markdown body)
2. **`scripts/status-snapshot.sh:20-23`** — Add to `KNOWN_AGENTS` array (roster display)
3. **`scripts/status-snapshot.sh:31-34`** — Add a case to the session-name-to-display mapping switch
4. **`server/serve.py:145`** — Add to `KNOWN_AGENTS` set in `create_dispatch()`
5. **`public/index.html:169`** — Add to `ICON` map for emoji display

Then create the tmux session manually:
```bash
tmux new-session -d -s <agent-name>
```

### The DO_NOT_BUILD Constraint

The project's DO_NOT_BUILD list explicitly says:

> **Subagent/profile spawning CLI** — Only the default profile exists. Not enough diversity to need a creation tool. Manual `hermes setup` for new profiles until count exceeds 5.

This was written when only the default Belial profile existed. The count is now **3** (Belial, ObsoleteBot, Ezekiel). When it reaches **5**, the constraint is lifted.

### Proposal: GUI Button "Register Agent"

Once the count reaches 5 (or if this decision is revisited), a GUI button on the dashboard could automate the multi-file registration process.

**What the button would do:**

1. Present a form:
   - Agent name (e.g., "Mephisto")
   - Session name (e.g., "claude-mephisto")
   - Model (dropdown: claude-opus-4.8, deepseek-v4-flash, deepseek-v4-pro, gemini-2.5-pro, local)
   - Effort level (dropdown: research, code-review, general, high)
   - Emoji icon (picker or text input)
   - Project directory (text input, e.g., "~/Mephisto")

2. On submit, write:
   - `docs/worker-profiles/<name>.md` — Profile YAML
   - **Patch** `scripts/status-snapshot.sh` — Add to `KNOWN_AGENTS` and the session-to-name mapping
   - **Patch** `server/serve.py` — Add to `KNOWN_AGENTS` set
   - **Patch** `public/index.html` — Add to `ICON` map

3. Optionally create the tmux session:
   - `tmux new-session -d -s claude-<name>`
   - Launch the agent: `tmux send-keys -t claude-<name> 'claude' Enter`

**Architecture note:** The DO_NOT_BUILD constraint applies to a *CLI* for spawning profiles. A GUI button on the Mission Control dashboard is a different surface. It could be argued that the GUI is the OS's primary interface (Principle 7) and that a button on the dashboard is not a "subagent/profile spawning CLI." This distinction would need Kevin's call.

**Estimated implementation:** ~3-4 hours for the form + backend endpoint + file patching.

**Simpler alternative:** A single `register-agent.sh` script that takes the 5 parameters and performs all the file updates. Run from terminal or triggered by a GUI button. Avoids the complexity of a GUI form builder while still automating the multi-file registration. ~1 hour.

### What Registration Creates

A new agent registration produces:

```
docs/worker-profiles/<name>.md          # Profile definition (human-readable)
scripts/status-snapshot.sh              # Updated KNOWN_AGENTS + mapping
server/serve.py                         # Updated KNOWN_AGENTS set
public/index.html                       # Updated ICON map
```

And optionally:
```
tmux session: claude-<name>             # Persistent agent session
~/.hermes/requests/                     # Now accepts dispatches to this agent
```

### Sources

- `DO_NOT_BUILD.md:16` — current constraint: "Manual `hermes setup` for new profiles until count exceeds 5"
- `DO_NOT_BUILD.md:18` — Claude `.claude/agents/*.md` subagents rejected in favour of Hermes-managed profiles
- `DESIGN_DECISIONS.md:72-78` — one general worker default, profiles deferred to Phase 5f
- `CONTRIBUTING.md:43` — one file per profile in `docs/worker-profiles/`
- `PRINCIPLES.md:100-107` — Principle 8: "Build what you need, not what the market has"
- `scripts/status-snapshot.sh:20-42` — agent registration points
- `server/serve.py:145` — known agents set
- `public/index.html:169` — icon mapping
- Count: Belial, ObsoleteBot, Ezekiel = 3 registered workers
