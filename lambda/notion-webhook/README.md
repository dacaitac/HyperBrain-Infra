# Notion Webhook Receiver (Lambda)

Pure protocol adapter for inbound Notion webhooks ([ADR-011], issues #41/#42). Notion posts to the
Lambda Function URL (the only public entry point — `daniel-ubuntu` exposes no port); the handler
authenticates the delivery and publishes the envelope
`{source_system: NOTION, message_id, delivery_channel, timestamp, payload}` to `sync-events.fifo`.
All Notion → domain mapping stays in the Core consumer (HU-14). The same URL receives the webhooks
of **all** Notion databases (Tasks, Cycles, future ones).

## Two authentication channels (ADR-011 v1.2.0)

| Channel | Auth | SSM secret | `delivery_channel` |
| :--- | :--- | :--- | :--- |
| Integration subscription | `X-Notion-Signature` (HMAC-SHA256 of the body) | `/hyperbrain/notion/webhook-secret` | `subscription` |
| DB automation | `X-HyperBrain-Token` bearer header (automations can't sign) | `/hyperbrain/notion/automation-token` | `automation` |

Unverifiable deliveries are **dropped but answered `200`** (WARNING in CloudWatch): Notion pauses
senders whose endpoint keeps failing, so the adapter never returns 4xx/5xx on an auth failure. The
security boundary is *what reaches SQS* (only authenticated deliveries), not the HTTP status.

## Layout

| File | Purpose |
| :--- | :--- |
| `handler.py` | Lambda handler (Python 3.12, stdlib + boto3 only) |
| `main.tf` / `variables.tf` / `outputs.tf` | Terraform module (own local state, like `terraform/sqs`) |

## Deploy (prod)

Prerequisite: `terraform/sqs` applied (`sync-events.fifo` exists). `terraform apply` is always
manual (#33) — CI only validates/plans.

```bash
# 1. Secrets in SSM (SecureString, never in Terraform state / git).
#    HMAC subscription key: the real value is Notion's verification_token (#42);
#    use a random placeholder until the subscription is registered.
aws ssm put-parameter --name /hyperbrain/notion/webhook-secret \
  --type SecureString --value "$(openssl rand -hex 32)" --overwrite
#    Automation bearer token: paste this same value into each automation's
#    X-HyperBrain-Token header in Notion.
aws ssm put-parameter --name /hyperbrain/notion/automation-token \
  --type SecureString --value "$(openssl rand -hex 32)" --overwrite

# 2. Provision
cd lambda/notion-webhook
terraform init && terraform apply

# 3. Record the Function URL in .env (SOPS) as NOTION_WEBHOOK_FUNCTION_URL
terraform output -raw function_url
```

## Smoke tests

```bash
# Dev (LocalStack with SERVICES=sqs,lambda up): exercises both auth channels + drops
scripts/localstack-lambda-notion-smoke-test.sh

# Prod (both channels forward 200, tampered auth drops 200; prints message_ids for the Core logs):
scripts/aws-lambda-notion-smoke-test.sh "$(terraform output -raw function_url)"
```

E2E check on `daniel-ubuntu`: `docker logs hyperbrain-core 2>&1 | grep <message_id>` and
`sync-events-dlq.fifo` must stay at `ApproximateNumberOfMessages=0`.

## Runbook

Full operational runbook (rotation, URL change, drop diagnostics) lives in
[`docs/02-architecture/infrastructure/notion-webhook-runbook.md`](https://github.com/dacaitac/HyperBrain-docs/blob/main/docs/02-architecture/infrastructure/notion-webhook-runbook.md).

**Rotate a secret** (subscription `webhook-secret` or automation `automation-token`):

```bash
aws ssm put-parameter --name /hyperbrain/notion/<param> \
  --type SecureString --value '<value>' --overwrite
# The handler caches secrets per container: force new containers afterwards
aws lambda update-function-configuration --function-name notion-webhook-receiver \
  --description "secret rotated $(date -u +%F)"
```

After rotating `automation-token`, update the `X-HyperBrain-Token` header in each Notion automation.

**Function URL changed** (recreated resource): update `NOTION_WEBHOOK_FUNCTION_URL` in `.env`
(SOPS) and re-register the Notion subscription endpoint (#42 runbook).

**Capture the subscription handshake**: Notion sends a one-time unsigned POST with
`verification_token`; the handler answers 200 and logs the token to CloudWatch
(`/aws/lambda/notion-webhook-receiver`).

**Metrics**: CloudWatch → Lambda `notion-webhook-receiver` (Invocations, Errors, Duration, Url4xx/5xx).

[ADR-011]: https://github.com/dacaitac/HyperBrain-docs/blob/main/docs/03-adrs/ADR-011-notion-webhooks-cycles-sync.md
