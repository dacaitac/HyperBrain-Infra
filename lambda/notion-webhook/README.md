# Notion Webhook Receiver (Lambda)

Pure protocol adapter for inbound Notion webhooks ([ADR-011], issue #41). Notion posts to the
Lambda Function URL (the only public entry point — `daniel-ubuntu` exposes no port); the handler
verifies `X-Notion-Signature` (HMAC-SHA256 of the raw body) and publishes the envelope
`{source_system: NOTION, message_id, timestamp, payload}` to `sync-events.fifo`.
All Notion → domain mapping stays in the Core consumer (HU-14). The same URL receives the webhooks
of **all** Notion databases (Tasks, Cycles, future ones).

## Layout

| File | Purpose |
| :--- | :--- |
| `handler.py` | Lambda handler (Python 3.12, stdlib + boto3 only) |
| `main.tf` / `variables.tf` / `outputs.tf` | Terraform module (own local state, like `terraform/sqs`) |

## Deploy (prod)

Prerequisite: `terraform/sqs` applied (`sync-events.fifo` exists). `terraform apply` is always
manual (#33) — CI only validates/plans.

```bash
# 1. Webhook secret in SSM (SecureString, never in Terraform state / git).
#    Before #42 registers the subscription, use a random placeholder:
aws ssm put-parameter --name /hyperbrain/notion/webhook-secret \
  --type SecureString --value "$(openssl rand -hex 32)" --overwrite

# 2. Provision
cd lambda/notion-webhook
terraform init && terraform apply

# 3. Record the Function URL in .env (SOPS) as NOTION_WEBHOOK_FUNCTION_URL
terraform output -raw function_url
```

## Smoke tests

```bash
# Dev (LocalStack with SERVICES=sqs,lambda up):
scripts/localstack-lambda-notion-smoke-test.sh

# Prod (signed 200 + tampered 401; prints the message_id to grep in Core logs):
scripts/aws-lambda-notion-smoke-test.sh "$(terraform output -raw function_url)"
```

E2E check on `daniel-ubuntu`: `docker logs hyperbrain-core 2>&1 | grep <message_id>` and
`sync-events-dlq.fifo` must stay at `ApproximateNumberOfMessages=0`.

## Runbook

**Rotate the webhook secret** (or store the real `verification_token` from #42):

```bash
aws ssm put-parameter --name /hyperbrain/notion/webhook-secret \
  --type SecureString --value '<verification_token>' --overwrite
# The handler caches the secret per container: force new containers afterwards
aws lambda update-function-configuration --function-name notion-webhook-receiver \
  --description "secret rotated $(date -u +%F)"
```

**Function URL changed** (recreated resource): update `NOTION_WEBHOOK_FUNCTION_URL` in `.env`
(SOPS) and re-register the Notion subscription endpoint (#42 runbook).

**Capture the subscription handshake**: Notion sends a one-time unsigned POST with
`verification_token`; the handler answers 200 and logs the token to CloudWatch
(`/aws/lambda/notion-webhook-receiver`).

**Metrics**: CloudWatch → Lambda `notion-webhook-receiver` (Invocations, Errors, Duration, Url4xx/5xx).

[ADR-011]: https://github.com/dacaitac/HyperBrain-docs/blob/main/docs/03-adrs/ADR-011-notion-webhooks-cycles-sync.md
