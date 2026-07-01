# AdVanced OS — Principles

> The seven design principles that govern every decision in this project. If a proposal violates a principle, it's rejected. If a principle proves wrong, we change it with a decision record.

## 1. Hermes Is the Orchestrator, Not Claude

Claude Code is a worker — a powerful one, but one worker among many. Hermes decomposes tasks, routes them, monitors execution, and reports. Claude writes code. DeepSeek does design review. Cron runs schedules. MCP servers provide tools.

**This means:**
- All dispatch routing logic lives in Hermes, not in Claude
- Worker profiles are Hermes-managed, not Claude's `.claude/agents/*.md`
- Tool scoping is enforced by Hermes via `delegate_task` toolset restrictions
- Claude does not trigger deploys, cron changes, or state mutations
- The orchestrator is infra-agnostic — works with any backend model

**Violation signal:** If someone proposes building a feature that depends on Claude being the orchestrator, the proposal is wrong.

## 2. Kevin Is the Top of the Architecture

Not the agent. Not the orchestrator. The human who approves, rejects, and redirects sits at the top of every diagram. No deploy happens without Kevin's approval. No architectural decision is made without Kevin's input.

**This means:**
- Every significant decision, deploy, or mutation routes to Discord for approval
- The Discord CLI is the primary interface — not a dashboard, not an API
- Clear deploy summaries (what changed, risk level, cost) are more important than fancy automation
- Global stop is always available, always visible
- The system optimizes for Kevin's confidence, not its own autonomy

**Violation signal:** If a feature makes Kevin less informed or less in control, it doesn't get built.

## 3. Safety Before Autonomy

The circuit breaker outranks every other feature. Spend caps, dispatch-depth limits, and a persistent global stop must exist before any dispatch automation. An accelerator without brakes is not an accelerator — it's a runaway.

**This means:**
- Phase 2 (circuit breaker) before Phase 1a (async shell bridge)
- Global stop flag persists to disk, not memory — watchdog restarts must not silently un-pause
- Cooperative halt: kill lets the current commit finish before hard-stopping
- Depth counter on correlation ID: prevents runaway chains across the async file boundary
- If it can auto-deploy, it must have a kill switch

**Violation signal:** If a feature enables autonomous action without a corresponding safety brake, it's gated until the brake exists.

## 4. Visibility Before Capability

The most valuable features are not the ones that make agents smarter. They're the ones that make agent work visible and controllable. Before adding a new capability, ensure the system can answer: what agents are running, what they did last, what they cost, and whether they finished.

**This means:**
- Phase 1b (correlation ID) and Phase 1c (cost logging) ship before any dispatch automation
- Phase 5a (structured observability) is higher priority than Phase 5f (worker profiles)
- A structured event log at dispatch/complete/fail boundaries is more valuable than a smarter dispatch router
- The "what happened yesterday" query should be answerable without reading raw terminal output
- Every dispatch creates an event. Every completion creates an event. Every failure creates an event.

**Violation signal:** If a feature makes the system more capable without making it more observable, justify why the capability outweighs the blind spot.

## 5. The Serial Channel Is a Design Feature, Not a Bug

Claude Code is a REPL puppeted through a single tmux session. This is not a limitation to work around — it's a constraint that simplifies the architecture. One serial channel means no race conditions, no concurrent state mutations, and a predictable execution model.

**This means:**
- No A2A protocol (designed for multi-runtime peer-to-peer)
- No bidirectional MCP bridge (deadlock risk)
- Async request files (`hermes-request`, `hermes-notify`) are the only worker→orchestrator communication
- Workers cannot call back into Hermes synchronously
- Only one dispatch at a time through the primary channel
- `delegate_task` subagents are the parallel escape hatch — isolated, tool-scoped, non-blocking

**Violation signal:** If a proposal assumes concurrent bidirectional communication between Hermes and a worker, it's architecturally wrong.

## 6. Manual Curation Beats Automated Self-Improvement

Automated systems that generate improvements (skill patches, memory entries, reference updates) produce noise. Kevin hand-filters the noise anyway. The correct design is machine-writeable for capture, human-curated for quality.

**This means:**
- No self-learning skill generation — Kevin patches skills on failure
- No automated dedup/pruning of the compound learning file — Kevin prunes when reviewing
- Skills are human-authored. The compound learning file is Hermes-written but human-curated.
- "Machine-writeable, human-curated" is the pattern for every accumulation system
- If automation would require a review step anyway, skip the automation

**Exception:** QA gates (Phase 5e) are automated by design — they check verifiable facts (file exists, test passes, branch pushed). These are not improvements, they are verification. Verification automation is correct.

**Violation signal:** If a proposal involves a system that autonomously modifies reference material without human review, it's over-engineered.

## 7. The GUI Is the Operating System's Interface

An operating system without a visible interface isn't an OS — it's a backend. AdVanced OS's primary interface is the Mission Control GUI: the at-a-glance dashboard showing every agent, every task, every cost, and every system health metric. The Discord CLI is the secondary interface — for control actions (dispatch, approve, stop) that are faster by keyboard.

**This means:**
- The GUI is a core feature, not a stretch goal. It ships alongside or before the control infrastructure.
- The GUI provides awareness (what's running, what happened, what it cost). The CLI provides control (dispatch, approve, stop). They are complementary, not competing.
- A 200-line static HTML page with inline CSS and JS that polls JSON endpoints is sufficient to start. It doesn't need to be a polished React app. It needs to exist.
- Cost data is displayed in the GUI, not sent as a weekly Discord text message. Spend-to-cap meters, per-worker cost breakdowns, and trend lines are visual by nature.
- The event log feeds the GUI's live feed. The status snapshot feeds the GUI's worker cards. The cost log feeds the GUI's spend meters. The GUI is the consumer of the observability infrastructure, not a separate system.
- `tmux capture-pane` + polling loops are the fallback when the GUI is unavailable, not the primary interface.

**Violation signal:** If someone proposes adding a feature to the observability layer without ensuring the GUI can display it, the feature is incomplete.

## 8. Build What You Need, Not What the Market Has

The 2026 Agentic OS market includes features we don't need: subagent spawning CLIs, self-improvement loops, one-click backup, autonomous L3 tiers. These are real features for other setups. They are not necessarily right for ours.

**This means:**
- Only two Hermes profiles exist (default + ornith). A profile spawning CLI is unnecessary until count exceeds 5.
- The compound learning file covers cross-session pattern accumulation. A Dreaming-style reviewer agent adds infrastructure cost for marginal benefit.
- Every market feature is evaluated against our actual pain points, not against what competitors ship.
- The GUI is the one exception to this principle — it's not a market-driven feature, it's a fundamental interface requirement for an operating system.
