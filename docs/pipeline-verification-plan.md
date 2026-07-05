# Pipeline Verification Test Plan — test-pipeline-validation

> **Pipeline UUID:** 9f4deedb-4ef3-437c-95f4-cb8766c80687
> **Created:** 2026-07-05T02:14:56Z
> **Goal:** Verify the development pipeline auto-advancement works end-to-end.

## Test Architecture

```
dispatch-consumer.sh (cron, 60s)
    │
    ├── Delivers dispatch → Ezekiel (research)
    │       │
    │       ├── Ezekiel produces output → research/output.md
    │       └── pipeline-advance.sh detects idle, captures output
    │              │
    │              └── Creates dispatch → Sammael (scaffold)
    │                     │
    │                     ├── Sammael produces framework → scaffold/output.md
    │                     └── pipeline-advance.sh detects idle, captures output
    │                            │
    │                            └── Creates dispatch → Belial (build)
    │                                   │
    │                                   ├── Belial implements + tests → build/output.md
    │                                   └── pipeline-advance.sh captures output
    │                                          │
    │                                          └── Generates report.md, state=done
    │
    └── pipeline-advance.sh runs at end of every poll cycle
```

## Checkpoints

### Stage 1: Research (Ezekiel) — COMPLETED ✅

| Check | Expected | Status |
|-------|----------|--------|
| Dispatch delivered | `research/sent_at` exists, agent=ezekiel | ✅ |
| Correlation ID | `9f4deedb-...:0` (stage 0) | ✅ |
| Ezekiel processes task | tmux pane shows activity, no "stuck" heartbeat | ✅ |
| Output captured | `research/output.md` > 100 bytes | ✅ 12,480 bytes |
| Timing guard | 67s between dispatch and capture (> 30s MIN_WORK) | ✅ |
| State advances | state → "scaffolding" | ✅ |

### Stage 2: Scaffold (Sammael) — COMPLETED ✅

| Check | Expected | Status |
|-------|----------|--------|
| Dispatch delivered | `scaffold/sent_at` exists, agent=sammael | ✅ |
| Correlation ID | `9f4deedb-...:1` (stage 1) | ✅ |
| Sammael produces framework | `pipeline-verify.sh` created in repo | ✅ |
| Output captured | `scaffold/output.md` > 100 bytes | ✅ 11,692 bytes |
| Timing guard | 75s between dispatch and capture (> 30s MIN_WORK) | ✅ |
| State advances | state → "building" | ✅ |

### Stage 3: Build (Belial) — IN PROGRESS 🔄

| Check | Expected | Status |
|-------|----------|--------|
| Dispatch delivered | `build/sent_at` exists, agent=claude-belial | ✅ 02:18:48Z |
| Correlation ID | `9f4deedb-...:2` (stage 2) | ✅ |
| Belial implements + tests | `build/output.md` captured | ⏳ Pending |
| Timing guard | > 30s from dispatch to capture | ⏳ Pending |
| State advances | state → "done" | ⏳ Pending |
| Final report | `report.md` generated | ⏳ Pending |

## Verification Procedures

### Automated: pipeline-verify.sh

```bash
# Standard check:
./scripts/pipeline-verify.sh 9f4deedb-4ef3-437c-95f4-cb8766c80687

# Strict check (includes CID timing + chain validation):
./scripts/pipeline-verify.sh 9f4deedb-4ef3-437c-95f4-cb8766c80687 --strict
```

Exit code 0 = all checks pass.

### Manual: Stage-by-stage inspection

```bash
PIPE=~/.hermes/dev-pipeline/9f4deedb-4ef3-437c-95f4-cb8766c80687

# Did each stage's dispatch get delivered?
cat $PIPE/research/sent_at
cat $PIPE/scaffold/sent_at
cat $PIPE/build/sent_at

# Was output captured?
wc -c $PIPE/research/output.md
wc -c $PIPE/scaffold/output.md
wc -c $PIPE/build/output.md

# Did state advance correctly through the chain?
cat $PIPE/state   # Should go: researching → scaffolding → building → done

# Is the final report present?
cat $PIPE/report.md
```

### Manual: Correlation ID chain validation

```bash
# The CID should chain: <uuid>:0 → <uuid>:1 → <uuid>:2
cat $PIPE/research/dispatch_cid    # expect :0
cat $PIPE/scaffold/dispatch_cid    # expect :1
cat $PIPE/build/dispatch_cid       # expect :2
```

### Manual: Pipeline-advance debug trace

```bash
# Watch pipeline-advance in action:
bash ~/AdVanced-OS/scripts/pipeline-advance.sh
# Check agent events log:
tail -20 ~/.hermes/logs/agent-events.log | grep pipeline
```

## Success Criteria

The pipeline is verified end-to-end when:

1. All 3 stages have `output.md` captured with substantive content (> 100 bytes)
2. State transitions: researching → scaffolding → building → done (in order)
3. `report.md` is generated with all 3 stage outputs merged
4. Correlation IDs chain correctly: `:0 → :1 → :2`
5. No agent was marked "stuck" during any stage
6. `pipeline-verify.sh --strict` exits 0

## Failure Modes (what Belial should watch for)

| Failure | Symptom | Recovery |
|---------|---------|----------|
| Agent stuck (heartbeat) | state → "failed", agent-event log shows "stuck" | Restart agent tmux session, re-init pipeline |
| Dispatch never delivered | `sent_at` missing for a stage | Check dispatch-consumer cron, request files in ~/.hermes/requests/ |
| Output too small | `output.md` < 100 bytes | Agent may have been interrupted; check tmux pane |
| CID chain broken | Stage counter doesn't increment | Check pipeline-advance.sh `create_next_dispatch` |
| MIN_WORK too short | Captured output truncated (agent still working) | Increase MIN_WORK env var, re-run |
| Global stop tripped | dispatch-consumer pauses, no advancement | Check ~/AdVanced-OS/scripts/global-stop.sh |
