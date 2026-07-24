# Replan Agenda Gateway (Lambda)

Command gateway for on-demand agenda replanning (HU-01b, issue #66). A POST to the Lambda Function
URL (the only public entry point — no port is exposed on `daniel-ubuntu`) authenticates the caller
via a bearer token and publishes a `REPLAN_AGENDA` command to `user-commands.fifo`. The Core
`UserCommandsConsumer` picks it up and triggers the Prioritizer + Planner pipeline.

No request body is needed. The command envelope is generated entirely by the Lambda:

```json
{"command_type": "REPLAN_AGENDA", "command_id": "<uuid4>", "occurred_at": "<iso8601-utc>"}
```

`MessageGroupId` is fixed to `"user-commands"`; `MessageDeduplicationId` is the `command_id`,
so back-to-back calls within the SQS 5-minute deduplication window are idempotent.

### Optional sleep payload (HealthKit bridge)

A free Apple account cannot read HealthKit from the first-party app, so — as a provisional bridge —
an iOS Shortcut reads last night's sleep from Health and POSTs it in the request body. The Shortcut
sends the payload **double-encoded** under a `data` key:

```json
{"data": "{\"date\": \"23/07/2026 at 10:12 PM\", \"sample\": [{\"stage\": \"Core\", \"startDate\": \"...\", \"endDate\": \"...\", \"duration\": \"22:53\"}, {\"stage\": \"REM\", ...}]}"}
```

The Lambda undoes only that transport double-encoding (`json.loads` on the inner string) and forwards
the resulting object **verbatim** as the command's `sleep`:

```json
{"command_type": "REPLAN_AGENDA", "command_id": "<uuid4>", "occurred_at": "<iso8601-utc>",
 "sleep": {"date": "23/07/2026 at 10:12 PM",
           "sample": [{"stage": "Core", "startDate": "...", "endDate": "...", "duration": "22:53"},
                      {"stage": "REM", "startDate": "...", "endDate": "...", "duration": "31:21"}]}}
```

A body that already carries a `sleep` object directly (no `data` wrapper) is accepted as a fallback.

This is a **pure-protocol** adapter: the shapes above are informative only — the Lambda never
interprets, validates or reshapes the payload (the Core parses `{date, sample}` with a tolerant
reader). A missing, empty, or non-JSON body degrades silently to a replan-only command. Each
invocation logs `(sleep=attached|absent)` in CloudWatch for diagnostics; the payload contents are
never logged.

Unverifiable requests are **dropped but answered `200`** (WARNING in CloudWatch) — same defensive
pattern as the other Lambda adapters. The security boundary is *what reaches SQS*, not the HTTP
status.

## Layout

| File | Purpose |
| :--- | :--- |
| `handler.py` | Lambda handler (Python 3.12, stdlib + boto3 only) |
| `test_handler.py` | Local unit tests (stdlib only; stubs boto3 — `python3 test_handler.py`) |
| `main.tf` / `variables.tf` / `outputs.tf` | Terraform module (own local state, like `terraform/sqs`) |

## Deploy (prod)

Prerequisite: `terraform/sqs` applied (`user-commands.fifo` exists).
`terraform apply` is always manual — CI only validates/plans.

```bash
# 1. Create the bearer token in SSM (SecureString, never in Terraform state / git).
#    Use this same value in the caller (SentinelAPI, iOS Shortcut, etc.).
aws ssm put-parameter --name /hyperbrain/replan/token \
  --type SecureString --value "$(openssl rand -hex 32)" --overwrite

# 2. Provision
cd lambda/replan-agenda
terraform init && terraform apply

# 3. Record the Function URL in .env (SOPS) as REPLAN_AGENDA_FUNCTION_URL
terraform output -raw function_url
```

## Tests

```bash
# Local unit tests — logic only, no AWS (stdlib, boto3 stubbed):
python3 lambda/replan-agenda/test_handler.py

# Prod smoke: happy path (200 ok), sleep-body path (200 ok), drop path (200 ignored).
scripts/aws-lambda-replan-smoke-test.sh "$(terraform output -raw function_url)"
```

E2E check on `daniel-ubuntu` (or via `kubectl logs`): confirm `REPLAN_AGENDA` appears in Core logs
and `user-commands-dlq.fifo` stays at `ApproximateNumberOfMessages=0`.

## Token rotation

```bash
aws ssm put-parameter --name /hyperbrain/replan/token \
  --type SecureString --value '<new-value>' --overwrite
# Force Lambda container replacement to flush the in-memory cache:
aws lambda update-function-configuration --function-name replan-agenda \
  --description "token rotated $(date -u +%F)"
```

After rotating, update the token in every caller (SentinelAPI `.env`, iOS Shortcut, etc.).

## Metrics

CloudWatch → Lambda `replan-agenda` (Invocations, Errors, Duration, Url4xx/5xx).
