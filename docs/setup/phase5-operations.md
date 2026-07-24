# Phase 5 Operations

Phase 5 closes the delivery loop around the existing Mission Control service.
It does not add another agent bus, scheduler, database, or deployment path.

## Install

```bash
cd ~/AdVanced-OS
./scripts/phase5-setup.sh install
./scripts/dashboard-service.sh restart
./scripts/phase5-setup.sh status
```

The installer creates symlinks in `~/.hermes/scripts/`, initializes
`~/hermes-learnings.md`, and creates `~/vaults/kevin/tickets/`. Ticket intake
piggybacks on the existing one-minute Dispatch Queue Consumer job, so Phase 5
does not mutate Hermes cron configuration.

Mission Control remains available at `http://localhost:4001`.

The service intentionally uses `PrivateTmp=false`. Local tmux stores its server
socket under `/tmp/tmux-UID`; isolating `/tmp` would leave status snapshots
visible while breaking live Vox capture and all explicit agent controls.

## Concrete QA Gate (5e)

Every order issued in Mission Control chooses one concrete contract:

- **Committed delivery:** HEAD must advance after dispatch and the worktree must
  be clean. An optional branch, required-file list, and test command add checks.
- **Report-only:** the worker must return a non-empty result file. Optional
  required-file and command checks can still be added.

The task document includes an asynchronous completion command. The worker runs
that command after finishing; it writes a `qa` request and returns immediately.
The serial consumer invokes `scripts/qa-gate.sh`, records `qa_pass` or `qa_fail`,
and exposes the full check result in Mission Control.

State lives in `~/.hermes/task-runs/<request-id>/`:

```text
request.json   immutable delivery contract
state.json     baseline and current phase
result.json    concrete check results
result.md      optional report-only result
```

Useful inspection:

```bash
./scripts/qa-gate.sh status --request-id REQUEST_ID
```

Test commands are explicit operator input and execute with `bash -lc` in the
registered workspace. Keep them deterministic and non-interactive.

## Compound Learnings (5d)

Mission Control can append a tagged learning, or Hermes can use:

```bash
./scripts/compound-learning.sh add \
  "The dispatch consumer owns all task injection." \
  --tags "dispatch,architecture"
./scripts/compound-learning.sh show
```

New dashboard orders and async tickets receive a bounded copy of the learning
file in their task preamble. Nothing deduplicates, prunes, promotes, or deletes
entries automatically; Kevin remains the curator.

## Report-Only Tickets (5g)

Create a Markdown ticket in `~/vaults/kevin/tickets/` using the
[ticket schema](../references/ticket-schema.md). The next existing dispatch poll
claims it and queues it through the same circuit-breaker-protected serial lane.

Automatic intake is deliberately narrow:

- `mode` must be `report-only`.
- The default and allowed worker is `ezekiel`.
- The request carries `no_deploy`.
- A non-empty result is required by the QA gate.
- Passing QA moves the ticket to `pending_review`, never `done`.
- Kevin accepts or blocks the result in Mission Control.

To allow another report-only profile explicitly:

```bash
export HERMES_TICKET_AGENTS="ezekiel,another-read-only-profile"
```

Do not add a full-access coding worker to this list. Code-changing work should
be issued as a normal Mission Control order with the committed-delivery QA
contract.

## Recovery

- A global stop pauses both ticket intake and dispatch.
- A ticket left at `claimed` remains visible; it is not silently re-queued.
- A QA failure is durable in `result.json` and visible on the dashboard.
- A worker can safely repeat the same QA completion request; completed results
  are immutable and returned idempotently.
- No Phase 5 action approves or performs a deployment.
