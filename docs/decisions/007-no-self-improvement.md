# Decision: No Self-Improvement Loop

- **Date:** 2026-07-01
- **Status:** Approved
- **Context:** Automated vs human-curated system improvement

## Context

The 2026 Agentic OS market features self-improvement mechanisms — Anthropic's "Dreaming" (scheduled memory curation), Mihir Modi's "self-evolution" layer (eval-scored skills), and various automated skill-generation systems. These features promise systems that get better without human intervention. They also produce noise.

## Options Considered

1. **No self-improvement loop:** All system improvements are human-curated. Skills are manually authored. Reference files are manually pruned. The compound learning file is Hermes-writeable but Kevin-reviewed.
2. **Full self-improvement loop:** A reviewer agent reads past session transcripts, extracts patterns, deduplicates entries, prunes stale information, and writes structured updates to memory and skills. Anthropic's "Dreaming" model.
3. **Eval-scored skills with automated promotion:** Skills are scored by eval metrics. Underperforming skills are demoted or flagged. High-scoring skills are promoted to defaults. Mihir Modi's approach.

## Chosen Approach

Option 1 — No self-improvement loop. Manual curation is correct design.

## Rationale

- Option 2 produces patches Kevin hand-reviews anyway. Automated pruning makes decisions about what's "stale" that Kevin would make differently. The reviewer agent's judgment is not Kevin's judgment. The result is noise that Kevin filters — the same work as doing it manually, plus the cost of fixing automated mistakes.
- Option 3 assumes eval scores correlate with real-world utility. They don't. A skill that scores well on benchmarks can produce poor results in production. Automated promotion based on eval scores would promote the wrong skills.
- The compound learning file (Phase 5d) is the right level of automation: Hermes can append findings (machine-writeable), but Kevin curates what stays (human-curated). This captures the benefit of cross-session pattern accumulation without the noise of automated editing.
- Kevin's skill curation on failure is already the correct feedback loop: something breaks → Kevin fixes the skill → future tasks benefit. This is faster and more accurate than a reviewer agent that discovers the failure through session analysis.
- The "self-improvement loop" was the most over-engineered item in v1 of the Agentic OS plan. Claude Code's own review flagged it as such.

## Consequences

- System improvement speed is bounded by Kevin's review cycles. This is acceptable — Kevin is the domain expert.
- Skills only improve reactively (on failure), not proactively (via pattern analysis). If this becomes a problem — if the same category of failure repeats because Kevin didn't notice the pattern — revisit this decision.
- The compound learning file provides proactive improvement at low cost. Kevin reads it when dispatching tasks. If he sees a pattern worth canonizing, he promotes it to a skill. This is the right balance.
