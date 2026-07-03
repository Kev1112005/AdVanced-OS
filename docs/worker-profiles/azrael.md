# Worker Profile: azrael

> Hermes Agent orchestrator. Routes work to other agents, runs cron, holds terminal access.

## Metadata

- **Role:** Orchestrator
- **Status:** Active
- **Session:** `hermes` (tmux)
- **Dispatcher:** self — dispatches to other agents via `delegate_task`
- **Backend:** DeepSeek V4 Flash

## Configuration

```yaml
name: azrael
session: hermes
model: deepseek-v4-flash
effort: orchestrator
project: AdVanced OS
directory: ~

tools:
  - delegate_task   # Route work to other agents
  - cron            # Schedule recurring jobs
  - terminal        # Shell access
```

## When to Use

- Coordinating multi-agent work
- Scheduling and managing cron jobs
- Anything that needs to fan work out to Belial, Ornith, or ObsoleteBot

## When NOT to Use

- Direct coding — dispatch to `general` (Belial) instead
- Autonomous deploy or cron mutation without Kevin's approval (Safety Rule 5)
