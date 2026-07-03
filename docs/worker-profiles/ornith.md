# Worker Profile: ornith

> Local ollama agent. Cheap, offline inference for the Vox project. No cloud spend.

## Metadata

- **Role:** Local inference
- **Status:** Active
- **Session:** `ornith` (tmux)
- **Dispatcher:** `delegate_task` via Hermes
- **Backend:** ornith-9b (local ollama)

## Configuration

```yaml
name: ornith
session: ornith
model: ornith-9b
effort: local
project: Vox
directory: ~

tools:
  - Read        # Read files
  - Grep        # Search file contents
  - local inference
```

## When to Use

- Local, zero-cost tasks where latency and privacy beat raw capability
- Vox project work

## When NOT to Use

- Tasks needing frontier reasoning — dispatch to Belial (`general`) instead
- Anything requiring cloud tools the local model can't reach
