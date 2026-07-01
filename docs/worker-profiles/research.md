# Worker Profile: research

> Tool-scoped worker for read-only codebase exploration and web research. No write access.

## Metadata

- **Role:** Research & Exploration
- **Status:** Planned (Phase 5f)
- **Dispatcher:** `delegate_task` via Hermes
- **Backend:** Model-agnostic — works with DeepSeek, Claude, Gemini, or local

## Configuration

```yaml
name: research
model: deepseek-v4-flash  # Cheap — research doesn't need expensive reasoning
max_turns: 15
timeout_seconds: 300
output_format: markdown-summary

tools:
  - Read        # Read files
  - Glob        # Search file patterns
  - Grep        # Search file contents
  - Web search  # Internet research (when available)

disallowed_tools:
  - Write       # No file modification
  - Edit        # No file modification
  - Bash        # No command execution
  - Terminal    # No shell access
```

## When to Use

- Codebase exploration: "How is event cancellation currently handled?"
- Web research: "What patterns do other tools use for RSVP management?"
- Dependency analysis: "What files import this function?"
- Architecture discovery: "Map the data flow for coaching reports."

## When NOT to Use

- Any task that requires file modification — use the `general` profile instead
- Any task that requires running tests — use the `general` profile instead
- Security-sensitive code review — use the `code-review` profile instead (when implemented)

## Output Format

The research worker returns a structured summary:
```markdown
## Research: <topic>

### Findings
- 

### File References
- path/to/file.ts (line XX): relevant code or pattern

### Summary
- 

### Open Questions
- 

### Suggested Next Steps
- 
```
