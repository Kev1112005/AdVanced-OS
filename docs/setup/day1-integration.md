# Day 1 Integration — Circuit Breaker + Correlation ID + Cost Logging

Wiring the Day 1 scripts into Hermes Agent. These are **repo-side hooks** —
they run alongside Hermes, not as standalone services. Kevin/Orchestrator sets
them up; Hermes itself is not installed or configured here.

Phases covered: **2** (circuit breaker + global stop), **1b** (correlation ID),
**1c** (cost logging).

## 1. Placement

Keep the scripts in the repo and symlink them into `~/.hermes/scripts/` so
`git pull` keeps them current:

```bash
mkdir -p ~/.hermes/scripts ~/.hermes/logs
for s in correlation-id circuit-breaker global-stop cost-log; do
  ln -sf ~/AdVanced-OS/scripts/$s.sh ~/.hermes/scripts/$s.sh
done
```

Config stays in the repo; scripts default to `../config/circuit-breaker.yaml`
relative to their own location. Override per-call with `--config <path>`.

Paths are overridable via env / flags — nothing is hardcoded:
- `HERMES_STOP_FILE`   (global-stop.sh)  default `$HOME/.hermes/stop`
- `HERMES_COST_LOG`    (cost-log.sh)     default `~/.hermes/logs/cost-log.csv`
- `HERMES_WEEKLY_CAP`  (cost-log.sh)     default `20.0`

## 2. Where each script goes in the dispatch loop

### a. Interaction start → generate a root correlation ID
At the start of every user interaction (Kevin says X), mint a root ID:
```bash
CID="$(~/.hermes/scripts/correlation-id.sh generate)"   # -> <uuid>:0
```
On each chained sub-dispatch, increment before passing it down:
```bash
CHILD_CID="$(~/.hermes/scripts/correlation-id.sh increment "$CID")"
```

### b. Before every dispatch → circuit breaker check
Gate the dispatch. Non-zero exit = do not dispatch.
```bash
if ~/.hermes/scripts/circuit-breaker.sh check --correlation-id "$CID"; then
  # ... proceed with dispatch ...
else
  code=$?    # 1=global stop, 2=depth, 3=spend cap, 4=config
  # report blocking check to alerts channel, halt cooperatively
fi
```
The JSON on stdout is for machine parsing; the human-readable `BLOCKED: …`
line goes to stderr.

### c. After a dispatch completes → log the cost
Parse Claude Code's usage output and append a row:
```bash
~/.hermes/scripts/cost-log.sh log \
  --correlation-id "$CID" --model "claude-opus-4.8" \
  --input-tokens 15000 --output-tokens 3200 \
  --cache-read 5000 --cache-write 2000 \
  --cost-usd 0.45 --task "Implement Phase 2 circuit breaker"
```

## 3. Cron jobs

The breaker is invoked inline per dispatch (§2b) — not on a timer. The only
scheduled jobs are housekeeping:

```cron
# Weekly spend report to the officers channel — Monday 09:00
0 9 * * 1  ~/.hermes/scripts/cost-log.sh summary >> ~/.hermes/logs/weekly-summary.jsonl

# Clear a stale global-stop flag daily (belt-and-suspenders; the script also
# auto-expires flags older than 24h on read)
0 3 * * *  ~/.hermes/scripts/global-stop.sh status >/dev/null
```

Time-cap enforcement (`time_cap.max_minutes`) is done by the orchestrator
during monitoring, not by the breaker on dispatch — see PLAN.md Phase 5.

## 4. Emergency brake

```bash
~/.hermes/scripts/global-stop.sh set "Runaway dispatch loop detected"   # STOP
~/.hermes/scripts/global-stop.sh clear                                  # resume
```
Recovery details for every trip: `scripts/circuit-breaker/RESET.md`.

## 5. Verify each piece

```bash
cd ~/AdVanced-OS
scripts/correlation-id.sh generate                       # <uuid>:0
scripts/correlation-id.sh increment "abc:0"              # abc:1
scripts/global-stop.sh check && echo STOPPED || echo RUNNING   # RUNNING
scripts/global-stop.sh set test; scripts/global-stop.sh check  # STOPPED
scripts/global-stop.sh clear
scripts/circuit-breaker.sh check --correlation-id "$(scripts/correlation-id.sh generate)"   # PASS
scripts/cost-log.sh log --correlation-id "test:0" --model test \
  --input-tokens 10 --output-tokens 10 --cost-usd 0.01 --task "test"
scripts/cost-log.sh summary                              # JSON summary
```

All scripts use `set -euo pipefail` and pass `shellcheck scripts/*.sh`.
