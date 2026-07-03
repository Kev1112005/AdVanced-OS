# Worker Profile: ezekiel

> Ezekiel, Chief Librarian of the Dark Angels — read-only research and knowledge
> retrieval. Explores codebases and the web; never modifies. No write access.

## Metadata

- **Role:** Research & Knowledge Retrieval
- **Status:** Active
- **Session:** `ezekiel` (tmux, woken on demand)
- **Dispatcher:** Dashboard dispatch consumer (tmux) or `hermes -p ezekiel`
- **Backend:** deepseek-v4-flash
- **Persona:** `~/.hermes/profiles/ezekiel/SOUL.md`

## Configuration

```yaml
name: ezekiel
session: ezekiel
model: deepseek-v4-flash  # Cheap — research doesn't need expensive reasoning
effort: research
project: AdVanced OS
directory: ~

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

- Codebase exploration: "How is dispatch throttling currently handled?"
- Web research: "What patterns do other tools use for agent orchestration?"
- Dependency analysis: "What files import this function?"
- Architecture discovery: "Map the data flow from dashboard dispatch to tmux."

## When NOT to Use

- Any task that requires file modification — use the `general` profile (Belial)
- Any task that requires running tests or commands — use `general`
- Security-sensitive code review — use the `code-review` profile (when implemented)

## Output Format

Ezekiel returns a structured, sourced briefing (headers verbatim — see SOUL.md):
```markdown
## Research: <topic>

### Findings
- <claim> — [VERIFIED|INFERRED] (source)

### File References
- path/to/file.ext (line XX): what is there and why it matters

### Summary
- <the answer, in two or three plain sentences>

### Open Questions
- <what remains unknown, and where one would look next>

### Suggested Next Steps
- <concrete follow-up for the dispatcher or another profile>
```
