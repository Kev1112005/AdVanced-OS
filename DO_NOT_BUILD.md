# AdVanced OS — Do Not Build

> Explicit items we will NOT build, with rationale. If a developer agent proposes building something on this list, stop and explain why it's off-limits.

| Item | Why Not | What Instead |
|------|---------|-------------|
| **Full MCP server for Claude→Hermes** | Deadlock risk on serial tmux channel. Over-built for current tool count. | Two async shell commands (Phase 1a: `hermes-request`, `hermes-notify`) |
| **Self-learning skill generation** | Produces patches Kevin hand-reviews anyway. Manual curation is correct design. | Manual skill patching on failure. One-shot CI fix notes to self. |
| **A2A protocol between agents** | One serial tmux channel. No peers. | Async request files (Phase 1a) |
| **Session checkpointing** | Cannot serialize closed CLI's working context (Claude Code is a closed CLI). | Small, committed, idempotent tasks. Git state as recovery unit. |
| **Formal tracing DB** | Correlation ID + grep is sufficient for one-person system. | UUID column in existing logs (Phase 1b). Structured event log (Phase 5a). |
| **AIOS / Agno / LangGraph** | In-process frameworks that own the LLM loop. Claude Code is a closed CLI. | Tmux + cron + shell. |
| **Graceful degradation framework** | Single Docker host = no HA. Alert + back off is the correct response. | `if X down: alert Kevin + back off` |
| **Deploy Go/No-Go automation** | Kevin should approve every deploy. | Clear Discord approval UX (Phase 3). |
| **Self-improvement loop** | Produces references Kevin hand-filters anyway. Automated dedup/pruning generates noise. | Compound learning file (Phase 5d) — machine-writeable, human-curated. Same value, zero noise. |
| **Subagent/profile spawning CLI** | Only 2 profiles exist (default + ornith). Not enough diversity to need a creation tool. | Manual `hermes setup` for new profiles until count exceeds 5. |
| **Rubric-driven LLM grader (Outcomes)** | Using a separate LLM to grade output is expensive and introduces model bias. | Phase 5e — Hermes checks concrete success criteria with shell commands. Cheaper, faster, bias-free. |
| **Claude `.claude/agents/*.md` subagents** | Tied to Anthropic's infra. Assumes Claude is orchestrator, not Hermes. | Hermes-managed worker profiles (Phase 5f) — infra-agnostic, works with any backend. |
| **Loop self-critique / maker-checker LLM verifier** | Duplicates Decisions 006 (shell QA gate) and 007 (no self-improvement loop). Using an LLM to grade output reopens closed decisions on the rejected side. | Hermes-run QA gate (Phase 5e) checks concrete criteria with shell commands. Loop memory goes in the compound learning file (5d) — machine-writeable, human-curated. |
