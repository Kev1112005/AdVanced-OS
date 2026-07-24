# Decision 009: File-Backed Phase 5 Delivery Contract

## Context

Decision 006 requires Hermes to verify concrete success criteria after a worker
finishes. Phase 5g also needs report-only ticket intake without creating a
second dispatch path, an unattended action tier, or an LLM reviewer. The
existing dashboard queue previously deleted a request after tmux delivery, so
there was no durable baseline against which to run post-delivery checks.

## Options Considered

1. Parse natural-language acceptance criteria and ask another LLM to grade them.
2. Execute arbitrary verification text embedded in Markdown tickets.
3. Register an explicit JSON QA contract at dispatch, receive completion through
   the existing async request boundary, and store immutable check results.
4. Infer completion only from tmux prompt output and trust the worker's report.

## Chosen Approach

Use the existing request JSON as the delivery contract. Mission Control creates
typed `qa_checks`; the serial consumer records the git baseline at actual
delivery; the worker sends an asynchronous `qa` request; and
`scripts/qa-gate.sh` runs the checks from the registered workspace.

Task-run state is flat JSON under `~/.hermes/task-runs/`. Report-only tickets
share the same mechanism but require a captured result instead of a commit.
Ticket scanning runs inside the existing Dispatch Queue Consumer poll and is
restricted to an explicit report-only agent allowlist. Passing QA moves a
ticket to `pending_review`; only Kevin can mark it done.

## Rationale

- Typed checks preserve Decision 006's objective shell verification.
- The async completion request is deadlock-free and respects the serial tmux
  constraint.
- Capturing the baseline at delivery makes `commit_advanced` meaningful.
- Reusing the current consumer avoids scheduler mutation and competing queue
  drainers.
- An allowlisted report-only lane keeps ticket intake below the autonomous
  mutation boundary.
- Immutable result files are inspectable in Mission Control and with ordinary
  filesystem tools.

## Consequences

- Workers must execute the completion command included in the task document.
- Operator-supplied test commands execute in the registered workspace and must
  be deterministic and non-interactive.
- Natural-language acceptance criteria remain useful context but do not become
  executable checks unless represented by a typed QA field.
- Tickets can be automatically claimed and evaluated, but never automatically
  completed or deployed.
- Tool-scoped profile creation remains a separate, deferred Phase 5f concern.
