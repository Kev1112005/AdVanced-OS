# References

External sources consulted during AdVanced OS design. Index of all research material.

## Landscape Analysis

Full analysis with source-by-source breakdown: [docs/landscape/README.md](docs/landscape/README.md)

## Source Summary

| Source | Type | Key Takeaway | URL |
|--------|------|-------------|-----|
| Goldie Mission Stack | Commercial product | Visual dashboard + community. Validated: agents fail silently. | agentos.guide |
| disler/claude-code-hooks | Open source (1.5k ★) | Multi-agent observability via event hooks | github.com/disler/claude-code-hooks-multi-agent-observability |
| Mihir Modi's Agentic OS | Open source (MIT) | 7-layer architecture, cost analytics, eval-scored skills | dev.to, MIT |
| Danylo Pravda | Blog post | 6-layer Windows stack. Critique of "paid-community branding." | pravda.systems |
| Addy Osmani | Conference talk | 8 levels of AI coding. Compound learning via AGENTS.md | addyosmani.com |
| Digital Applied | Blog post | 5 multi-agent patterns with cost/quality comparison | digitalapplied.com |
| Sola Fide | Blog post | Four-step verification: Delegate → Review → QA → Commit | solafide.ca |
| Zamp | Enterprise product | Agent org charts, governance, shared filesystem | zamp.ai |
| MindStudio | Enterprise blog | 5 control layers for production agent reliability | mindstudio.ai |
| Google Antigravity 2.0 | Platform release | Subagents, hooks, plugins. Agentic IDE. | antigravity.google |
| Anthropic "Dreaming" | Feature launch (May 2026) | Scheduled memory curation across sessions | docs.anthropic.com |
| Anthropic "Outcomes" | Feature launch (May 2026) | Rubric-driven self-correction with separate grader | docs.anthropic.com |

## Protocols

- **MCP (Model Context Protocol):** modelcontextprotocol.io — Primary agent→tool protocol
- **A2A (Agent-to-Agent):** a2a-protocol.org — Not used (serial channel constraint)
- **ACP (Agent Communication Protocol):** IBM — Not used (enterprise scope)

## Tools

- **Hermes Agent:** hermes-agent.nousresearch.com/docs — The orchestrator
- **Claude Code:** docs.anthropic.com — Primary coding worker
- **Obsidian:** obsidian.md — Human-facing memory vault
- **OpenBrain MCP:** github.com/nousresearch/openbrain — Agent-facing memory
