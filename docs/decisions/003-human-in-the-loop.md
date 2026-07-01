# Decision: Human-in-the-Loop, Not Autonomous Deploy

- **Date:** 2026-07-01
- **Status:** Approved
- **Context:** Deploy authorization and system autonomy boundaries

## Context

AdVanced OS can auto-build, auto-PR, auto-merge, and auto-deploy to a production Docker host. With the async shell bridge (Phase 1a), workers can trigger Hermes to dispatch new tasks. Without human gates, the system can autonomously build and ship code to production.

## Options Considered

1. **Human-in-the-loop:** Kevin approves every deploy. Confirmation requested with a summary of changes, risk level, and cost.
2. **Full autonomy:** Trust the system to deploy when CI passes. No human approval needed.
3. **Conditional autonomy:** Autopilot for low-risk changes (config, docs). Human approval for schema migrations, dependency changes, or spend above threshold.

## Chosen Approach

Option 1 — Kevin approves every deploy. No exceptions.

## Rationale

- Single-user system. There is no second operator to catch mistakes. Kevin is the only reviewer.
- The deploy approval UX (Phase 3) — clear summary, risk level, cost, confirm/deny — takes seconds to use. The friction is negligible.
- Full autonomy (Option 2) has no recovery mechanism if the system makes a bad decision. The only way to fix a bad deploy is to revert it, which costs more time than the seconds spent approving it.
- Conditional autonomy (Option 3) requires a risk classifier that makes autonomous decisions about what counts as "low risk." That classifier is itself a source of errors. Config changes can break production. Docs changes (if auto-deployed to a public site) can publish incorrect information.
- The global stop command (`/stop-hermes`) covers emergency situations where Kevin needs to halt everything immediately. Approval is for planned work.
- This principle extends beyond deploys: no cron mutation without Kevin, no spending above cap without Kevin, no architectural changes without Kevin.

## Consequences

- Deploy speed is bounded by Kevin's response time. This is acceptable — production deploys should not be instantaneous.
- Phase 3 (Discord approval UX) is critical path. Without clean deploy summaries, the approval step becomes a bottleneck.
- The system is explicitly NOT autonomous. This is a feature, not a limitation.
