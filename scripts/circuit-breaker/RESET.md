# Circuit Breaker — Reset & Recovery

What happens when the circuit breaker trips, and how Kevin gets things moving
again. The breaker is a **gate before every dispatch** (Decision 002:
"circuit breaker before accelerator"). It never kills a running commit — the
halt is **cooperative**: the current commit finishes, then Hermes stops
dispatching.

## Exit codes (what tripped)

| Code | Check | Meaning |
|------|-------|---------|
| 0 | — | PASS, dispatch allowed |
| 1 | global stop | `/tmp/hermes-stop` flag is set |
| 2 | dispatch depth | correlation ID depth >= `dispatch_depth.max` |
| 3 | spend cap | weekly spend >= `spend_cap.weekly_usd` |
| 4 | config | missing/unreadable config or bad correlation ID |

## Failure modes in practice

### 1. Global stop (exit 1) — "BLOCKED: Global stop flag set"
Someone (Kevin, a watchdog, or a runaway-loop detector) hit the emergency
brake. Every dispatch is refused until the flag is cleared. The flag lives on
disk (`/tmp/hermes-stop`) so it survives a watchdog restart.

**Recover:**
```bash
scripts/global-stop.sh status    # see who/why/when
scripts/global-stop.sh clear     # release the brake
```
The flag auto-clears if it's older than 24h (stale watchdog leftover) — you'll
see a warning when that happens.

### 2. Dispatch depth (exit 2) — "BLOCKED: Dispatch depth limit reached (3)"
A single request chained too many sub-dispatches (A dispatches B dispatches C…).
This is the anti-runaway guard. Depth is carried in the correlation ID
(`<uuid>:<depth>`) and incremented on each chained dispatch.

**Recover:** usually you *don't* — this is working as intended. If a task
legitimately needs deeper chaining, raise `dispatch_depth.max` in
`config/circuit-breaker.yaml`, or restart the chain from a fresh root ID
(`correlation-id.sh generate`, depth 0).

### 3. Spend cap (exit 3) — "BLOCKED: Weekly spend cap reached ($22.50/$20.00)"
This week's summed cost (from `cost-log.csv`) hit the weekly limit. Everything
pauses until the week rolls over (Monday 00:00 local) or the cap is raised.

**Recover — temporary bump:**
```bash
# edit the cap for the rest of this week
$EDITOR config/circuit-breaker.yaml     # spend_cap.weekly_usd: 20.0 -> 30.0
```
The log is append-only; the cap resets to the config value automatically next
Monday. Prefer a small temporary bump over disabling the check.

### 4. Config error (exit 4)
Config file missing, or the correlation ID was malformed. Check the `--config`
path and that the ID looks like `<uuid>:<depth>`.

## The cooperative halt procedure

1. Breaker returns non-zero **before** the next dispatch.
2. The in-flight commit/task runs to completion — nothing is killed mid-work.
3. Hermes stops pulling new work and reports the blocking check to
   `alerts.channel` (see config).
4. Kevin clears the condition (above), then dispatching resumes on the next
   cycle. No manual "un-pause" needed beyond clearing the cause.

## Quick reference

```bash
scripts/global-stop.sh set "reason"   # trip global stop manually
scripts/global-stop.sh clear          # release it
scripts/cost-log.sh summary           # see spend vs cap
scripts/circuit-breaker.sh check --correlation-id "$(scripts/correlation-id.sh generate)"
```
