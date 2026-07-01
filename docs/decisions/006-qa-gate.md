# Decision: Hermes-Run QA Gate, Not LLM-Based Grading

- **Date:** 2026-07-01
- **Status:** Approved
- **Context:** Post-dispatch verification pattern for AdVanced OS

## Context

After a worker signals completion, the system needs to verify the output before reporting success to Kevin. The verification approach determines cost, reliability, and whether the gate is worth having.

## Options Considered

1. **Hermes-run QA gate:** After worker signals completion, Hermes checks concrete success criteria using shell commands. File exists? Test passed? Branch pushed? Commit landed? All verifiable with shell.
2. **LLM-based rubric grading:** A separate LLM instance (Anthropic's "Outcomes" pattern) evaluates the worker's output against a rubric in its own context window. The grader is uninfluenced by the worker's reasoning.
3. **No QA gate:** Trust the worker's self-report. Kevin verifies manually.

## Chosen Approach

Option 1 — Hermes-run QA gate. Shell commands, not model calls.

## Rationale

- Option 2 requires a model call per task for grading. For Claude Code at ~$3-5/hour of usage, adding an LLM grader per task increases cost by 10-30% with no guarantee of catching errors a shell command would miss.
- Option 2 introduces model bias: a grader LLM may approve output the worker LLM produced and reject similar output from a different worker. The grader's judgment is not objective.
- Option 3 was the pre-OS state. It had the "agents say 'done' while errored on step four" problem. Something is needed between worker completion and Kevin notification.
- Option 1 is cheap (shell commands cost nothing), objective (a test either passes or doesn't), and fast (sub-second). The only thing it misses is subjective quality evaluation (code style, architectural fit), which is Kevin's job anyway.
- The task document already includes a success criteria section. The QA gate reads those criteria and checks them. No new document format needed.

## What the QA Gate Checks

| Criterion | Shell Check | Example |
|-----------|------------|---------|
| Commit landed | `git log --oneline -1` | Expected commit message present |
| Branch correct | `git branch --show-current` | Expected branch name matches task doc |
| Tests pass | Run test suite on relevant files | Exit code 0 |
| File created | `test -f <path>` | Expected output file exists |
| File modified | `git diff --name-only HEAD~1` | Expected files in diff |
| No unstaged changes | `git status --short` | Empty output |

## Consequences

- Subjective quality is not verified by the gate. Kevin still reviews output for code style, architectural fit, and design decisions.
- Each task doc must have a `## Success Criteria` section with verifiable criteria. This adds ~30 seconds to task doc writing.
- The QA gate is cheap enough to run unconditionally on every task completion.
- If a criterion requires human judgment (e.g., "code follows project conventions"), it's excluded from the gate and Kevin checks it manually.
