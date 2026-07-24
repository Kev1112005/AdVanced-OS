# Discord Deployment Approval

Phase 4 uses the existing Hermes Discord gateway and durable files. A deployment
request is inert until Kevin records an explicit decision. No agent may infer
approval from conversation, reactions, CI success, or risk level.

## Install

Keep the command and skill linked to this checkout so `git pull` updates both:

```bash
mkdir -p ~/.hermes/scripts ~/.hermes/skills
ln -sfn ~/AdVanced-OS/scripts/deploy-approval.sh \
  ~/.hermes/scripts/deploy-approval.sh
ln -sfn ~/AdVanced-OS/skills/deployment-approval \
  ~/.hermes/skills/deployment-approval
```

By default, requests go to the Discord `channel_id` in
`config/circuit-breaker.yaml`. Override it without editing committed
configuration:

```bash
export HERMES_DEPLOY_APPROVAL_TARGET="discord:CHANNEL_ID"
```

## Create a Request

The deploy pipeline prepares a risk summary, writes the durable request, and
notifies Kevin:

```bash
deploy_id="obsoletebot-482"
~/.hermes/scripts/deploy-approval.sh request \
  --id "$deploy_id" \
  --title "ObsoleteBot PR #482" \
  --repository "Kev1112005/ObsoleteBot" \
  --ref "main@abc123" \
  --risk medium \
  --summary "12 checks passed; no schema migration" \
  --checks "CI green; image built; rollback image available" \
  --rollback "Redeploy image sha256:..."
```

The request is written to `~/.hermes/deploy-requests/<id>.json`. If Discord
delivery fails, the request remains pending and can be sent again:

```bash
~/.hermes/scripts/deploy-approval.sh notify --id "$deploy_id"
```

Mission Control reads the same request directory, so GUI and Discord approvals
refer to one durable object.

## Kevin’s Discord Responses

The `deployment-approval` Hermes skill recognizes only explicit commands that
include the deployment ID:

```text
approve deploy obsoletebot-482
deny deploy obsoletebot-482 rollback plan is incomplete
notify deploy obsoletebot-482
```

Bare replies such as `yes`, `ship it`, or a reaction are not authorization.
Hermes records the decision in `~/.hermes/approvals/<id>.json` and reports the
durable state. Identical repeated decisions are idempotent. A conflicting second
decision is rejected instead of overwriting the first.

## Gate the Deploy

Immediately before any production mutation, the deploy pipeline must check the
record:

```bash
if ~/.hermes/scripts/deploy-approval.sh check --id "$deploy_id"; then
  # Run the separately defined deployment procedure.
  :
else
  case $? in
    1) echo "deployment is still pending" ;;
    2) echo "deployment was denied" ;;
    *) echo "deployment request is invalid" ;;
  esac
  exit 1
fi
```

Exit code `0` is the only state that permits deployment. Approval does not
itself run a deploy command.

## Inspect and Test

```bash
~/.hermes/scripts/deploy-approval.sh list
~/.hermes/scripts/deploy-approval.sh status --id "$deploy_id"

# Exercise request formatting without sending Discord traffic:
HERMES_DEPLOY_NOTIFY=0 \
  ~/.hermes/scripts/deploy-approval.sh request \
  --id smoke-test --title "TEST ONLY" --summary "No deployment will run"
```

Tests should point `HERMES_DEPLOY_REQUEST_DIR` and `HERMES_APPROVAL_DIR` at a
temporary directory. Never test against a real production deployment ID.
