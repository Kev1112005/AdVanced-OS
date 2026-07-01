# AdVanced OS — Landscape Analysis

> The 2026 "Agentic OS" market, broken down by camp. All sources consulted during design.

## The Three Camps

There is no single "Agentic OS" standard. The term is claimed by three distinct groups with different goals, audiences, and architectures. Understanding which camp a source belongs to is essential context for any design decision.

### 1. The Goldie Ecosystem (Most Commercially Visible)

**Source:** agentos.guide, juliangoldie.com, aisucesslabjuliangoldie.com

**What it is:** A downloadable zip pre-wiring Hermes + Claude + OpenClaw + NotebookLM + Obsidian. Sells as $59/mo "AI Profit Boardroom" membership (3,600+ members).

**Architecture (4-layer "Goldie Mission Stack"):**
- **Intelligence** — Claude Desktop (plan/spec) + Claude Code (code)
- **Execution** — OpenClaw (browser automation)
- **Research** — Hermes Agent (multi-step research)
- **Self** — Obsidian + OMI (memory/personal context)

**Key product features:**
- "Mission Control" visual dashboard — reactor core with orbiting agent nodes (Claude, Hermes, Gemini, Codex, OpenClaw)
- Nodes light up when active, go dark when stalled
- Real-time task ticker showing what started, finished, handed off
- Click-to-inspect panels per agent
- Weekly live coaching calls (community layer)

**Danylo Pravda's critique (pravda.systems, June 2026):**
> "A real, open-source core (Claude Code, Hermes, OpenClaw) with a paid-community branding layer bolted on top: the 'Pantheon of personas,' the overnight 'dreaming' loop, the 'Mission Control' dashboards — sold through subscription communities and absent from any official codebase."

**Relevance to AdVanced OS:** Validates the "agents fail silently" pain point. The dashboard concept is aspirational — we build the data layer first (5a, 5b), add visuals only if needed (5c). The Pravda critique confirms that building around Hermes (not around a paid ecosystem) is the right approach.

### 2. Open-Source Build-Your-Own

#### Mihir Modi's Agentic OS (May 2026)

**Source:** dev.to, MIT license

**Architecture (7 layers):**
1. Agent Router — routes code→opencode, memory→Hermes, research→Gemini
2. Business Brain — structured knowledge
3. Skills Hub + Eval — SKILL.md + learnings + eval + score history
4. Memory Graph — SQLite FTS5 + shared brain/
5. Scheduler + Health — APScheduler jobs
6. Self-Evolution — agents improve from eval scores
7. Identity / Constitution — foundational rules

**12 features shipped:** 3-agent engine, 16 skills with eval scoring, cron scheduler, cost analytics, one-click backup, audit trail, prompt library, dark/light theme, standards system, plugin registry, client timeout, SQLite FTS5 memory.

**Relevance:** The skills-with-eval-scoring and cost analytics patterns are directly applicable. His "self-evolution" layer is what we explicitly chose NOT to build (see DESIGN_DECISIONS.md), but the eval-scored skills approach influenced our worker profiles (Phase 5f).

#### disler/claude-code-hooks (1.5k ★ GitHub)

**Source:** github.com/disler/claude-code-hooks-multi-agent-observability

**Approach:** Claude Code hooks emit structured events as agents work. These feed into a dashboard showing which agent is doing what, with which tools, using swim lane visualization for parallel agents.

**Features:** Swim lanes, human-in-the-loop escalation points, agent skills as composable units, event tracking at every dispatch/complete/fail boundary.

**Relevance:** Directly inspired our Phase 5a (structured observability). The event-at-boundary pattern — emit on dispatch, emit on complete, emit on fail — is the same approach. We implement it with Hermes shell wrappers instead of Claude Code hooks (because Hermes is the orchestrator, not Claude).

#### jayhemnani/agentic-os

**Source:** GitHub

**Approach:** FastAPI orchestrator + pgvector PostgreSQL for long-term memory and context. Lightweight, containerized.

**Relevance:** Confirms the pattern of a central orchestrator with vector-backed memory. Not directly applicable — we already have OpenBrain MCP for vector memory and Hermes as the orchestrator.

### 3. Enterprise Orchestration

#### Zamp

**Source:** zamp.ai/blogs/ai-agent-operating-system-the-orchestration-layer (June 2026)

**Approach:** AI digital-workforce and orchestration platform. Shared filesystem for agents and teams, managed agents with 1,000+ tools, org charts defining responsibilities and permissions, governance (which agents can spend money, email customers, require human approval).

**Concepts:** "AI agent org chart" — a map of which agents exist, what each is responsible for, who delegates to whom. Governance boundaries: which agents can spend money, which must pause for human approval.

**Relevance:** The "org chart" concept influenced our AGENTS.md worker registry. Not directly applicable at enterprise scale, but the idea of named agents with defined responsibilities is correct.

#### MindStudio

**Source:** mindstudio.ai/blog

**Approach:** Five control layers that determine agent reliability at scale. Smart orchestrator model with observability, cost tracking, and quality gates.

**Relevance:** Confirms the control-layer approach we independently designed. No new patterns.

## Multi-Agent Orchestration Patterns (Digital Applied, May 2026)

**Source:** digitalapplied.com/blog/multi-agent-orchestration-5-patterns-that-work

Five patterns dominate production multi-agent systems in 2026:

| Pattern | Topology | Coordination Overhead | Failure Mode | Our Use |
|---------|----------|----------------------|-------------|---------|
| **Fan-out** | One coordinator → parallel specialists | Low | Partial — one branch fails, how to aggregate remaining results? | Not used — serial tmux channel prevents true parallel dispatch |
| **Pipeline** | Sequential, each stage feeds next | Low | Cascade — bad mid-stage contaminates everything after | Cron job chains, deploy pipeline |
| **Debate** | Same question to multiple agents, adjudicate | High (~2.5× cost) | Adjudicator becomes bottleneck | Not used — expensive, no clear benefit for single-user |
| **Supervisor** | Coordinator delegates non-overlapping tasks | Medium | Coordinator misses context | **Our architecture** — Hermes delegates, synthesizes results |
| **Swarm** | Many agents, emergent coordination | High (300-agent scale) | Unpredictable behavior at scale | Not used — overkill for single-user |

**Key insight:** Our architecture is the **Supervisor** pattern. Hermes is the coordinator, Claude/DeepSeek/cron are the specialists. This is the most proven pattern for our use case — it's the 2026 default for production multi-agent systems.

## Claude-Specific Features (Anthropic, May 2026)

These were researched as part of the landscape analysis but **are not part of AdVanced OS's architecture**. They inform what we explicitly chose NOT to build.

| Feature | What It Does | Why We Skip It | Our Replacement |
|---------|-------------|----------------|-----------------|
| **Native subagents** (`Agent` tool, `.claude/agents/*.md`) | Claude spawns subagents with isolated context, tool scoping, per-model selection | Tied to Anthropic infra. Assumes Claude is orchestrator. | Hermes-managed worker profiles (Phase 5f) via `delegate_task` with toolset restrictions |
| **"Dreaming"** (scheduled memory curation) | Reviewer agent extracts patterns across sessions, deduplicates, prunes stale entries | Requires Anthropic's managed agents platform. Automated pruning produces noise. | Compound learning file (Phase 5d) — Hermes-curated, human-reviewed |
| **"Outcomes"** (rubric-driven self-correction) | Separate Claude instance evaluates output against rubric in own context window | LLM-as-judge is expensive and introduces model bias. | Hermes-run QA gate (Phase 5e) — concrete success criteria checked with shell commands |
| **Four-step verification** (Delegate → Review → Quality-fix → Commit) | Mandatory QA pass before commit, gated on `approved: true` | Useful pattern, but Claude-internal `approved: true` flag. | Hermes enforces the gate after worker signals completion, before reporting to Kevin |

## What the Market Agrees On

Despite different audiences and architectures, every source converged on four points:

1. **Visibility is the #1 problem.** Goldie, disler, Mihir, Pravda — all say "agents fail silently and you can't see which step broke." This is the primary problem AdVanced OS solves.

2. **Memory must persist between sessions.** Every single source has a persistent memory layer. Obsidian, OpenBrain, SQLite FTS5, pgvector — different implementations, same requirement.

3. **Safety brakes are non-negotiable.** Spend caps, dispatch limits, kill switches. Not a nice-to-have — a prerequisite. The sources that don't have them (Goldie's stack) rely on community support rather than engineering.

4. **The operator is the highest layer.** Not the agent, not the orchestrator. The human who approves, rejects, and redirects is the top of every working architecture. Systems that optimize for autonomy first fail in production.

## What Our Analysis Added

After two research passes, we identified features not present in any single source:

- **Compound learning file (5d):** No source had a Hermes-curated, task-doc-injected cross-session reference. Goldie's OMI comes closest but is a separate service.
- **Hermes-run QA gate (5e):** No source had a non-LLM QA gate. Anthropic's "Outcomes" uses an LLM grader. We check shell facts instead.
- **Tool-scoped worker profiles (5f):** Claude has native subagents. We have `delegate_task` with toolset restrictions — infra-agnostic, works with any backend.
