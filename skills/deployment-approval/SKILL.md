---
name: deployment-approval
description: "Handle explicit deployment approval, denial, repeat-notification, and status requests for AdVanced OS."
version: 1.0.0
author: AdVanced OS
platforms: [linux]
metadata:
  hermes:
    tags: [Deployment, Approval, Discord, Human-in-the-Loop, AdVanced-OS]
---

# Deployment Approval

Use this skill when Kevin asks to approve, deny, repeat, or inspect a deployment
request. The durable request and decision files are the authority; conversation
alone is never approval.

## Commands

```bash
~/AdVanced-OS/scripts/deploy-approval.sh list
~/AdVanced-OS/scripts/deploy-approval.sh status --id DEPLOYMENT_ID
~/AdVanced-OS/scripts/deploy-approval.sh notify --id DEPLOYMENT_ID
~/AdVanced-OS/scripts/deploy-approval.sh decide \
  --id DEPLOYMENT_ID --decision approve --by "Kevin via Discord"
~/AdVanced-OS/scripts/deploy-approval.sh decide \
  --id DEPLOYMENT_ID --decision deny --reason "REASON" --by "Kevin via Discord"
```

## Interpretation Rules

1. Require the exact deployment ID. Never treat a bare “yes,” “ship it,” reaction,
   or approval for another request as authorization.
2. Accept `approve deploy ID` only from Kevin. Record it with `--decision approve`.
3. Accept `deny deploy ID REASON` only from Kevin. Preserve the reason with
   `--decision deny`.
4. Treat `notify deploy ID` as a request to repeat the deployment summary, not as
   approval.
5. Before responding, run `status --id ID` and report the durable decision state.
6. A repeated identical decision is idempotent. A conflicting second decision is
   rejected and must be resolved manually; never overwrite the first decision.
7. Do not run deployment commands. This skill records Kevin’s decision only. The
   separate deployment pipeline must call `check --id ID` and may proceed only
   when it exits 0.
8. **Escalation default (Decision 010, tiered autonomy):** if a Tier 2 request has
   been pending more than 4 hours, do not block the pipeline and do not nag.
   Defer it to the next Monday docket (the docket-prep script surfaces queued
   requests with age). Never auto-approve; never drop the request. A pending
   request is reported on the docket until Kevin decides or the requester
   retracts it.

## Response Format

Reply with the deployment ID, recorded state (`approved`, `denied`, or `pending`),
operator identity, timestamp when available, and reason when denied. Keep the
response explicit and brief.
