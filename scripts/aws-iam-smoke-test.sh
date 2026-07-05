#!/usr/bin/env bash
# IAM policy smoke test — validates least-privilege boundaries per ADR-001.
# Run after `terraform apply` on daniel-ubuntu.
#
# Usage (credenciales vía env vars):
#   CORE_KEY_ID=AKIAxxx CORE_SECRET=xxx \
#   SENTINEL_KEY_ID=AKIAxxx SENTINEL_SECRET=xxx \
#   bash scripts/aws-iam-smoke-test.sh
#
# Atajo en daniel-ubuntu (lee de los archivos ya existentes):
#   source <(grep '^AWS_ACCESS_KEY_ID\|^AWS_SECRET_ACCESS_KEY' ~/hyperbrain-deploy/.env \
#            | sed 's/AWS_ACCESS_KEY_ID/CORE_KEY_ID/;s/AWS_SECRET_ACCESS_KEY/CORE_SECRET/')
#   source <(sed 's/SENTINEL_KEY_ID/SENTINEL_KEY_ID/;s/SENTINEL_SECRET/SENTINEL_SECRET/' ~/sentinel-sqs-key.txt)
#   bash scripts/aws-iam-smoke-test.sh
#
# Qué valida:
#   hyperbrain-core-sqs   → SendMessage/ReceiveMessage/GetAttributes en las 6 colas  [allow ×5]
#   event-sentinel-api-sqs → SendMessage sync-events.fifo                            [allow ×1]
#   event-sentinel-api-sqs → SendMessage core-events / ia-jobs / sync-events-dlq     [deny  ×3]
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
PASS=0; FAIL=0; SKIP=0

check()  { printf "  %-52s" "$1"; }
ok()     { echo "✓ allow";  PASS=$((PASS+1)); }
denied() { echo "✓ deny";   PASS=$((PASS+1)); }
fail()   { echo "✗  $1";    FAIL=$((FAIL+1)); }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "UNKNOWN")
BASE="https://sqs.${REGION}.amazonaws.com/${ACCOUNT}"
TS=$(date +%s%N)

echo "=== HyperBrain IAM Policy Smoke Test ==="
echo "Account: ${ACCOUNT} | Region: ${REGION}"
echo ""

# ── Resolver credenciales ──────────────────────────────────────────────────────
HAVE_CORE=0; HAVE_SENTINEL=0

[[ -n "${CORE_KEY_ID:-}"     && -n "${CORE_SECRET:-}"     ]] && HAVE_CORE=1
[[ -n "${SENTINEL_KEY_ID:-}" && -n "${SENTINEL_SECRET:-}" ]] && HAVE_SENTINEL=1

if [[ ${HAVE_CORE} -eq 0 ]] && aws configure get aws_access_key_id --profile hyperbrain-core &>/dev/null; then
  HAVE_CORE=2  # 2 = usar perfil nombrado
fi
if [[ ${HAVE_SENTINEL} -eq 0 ]] && aws configure get aws_access_key_id --profile event-sentinel &>/dev/null; then
  HAVE_SENTINEL=2
fi

# Helper: ejecutar aws con credenciales del service account
aws_as() {
  local mode="$1"; shift
  if [[ "${mode}" == "core" ]]; then
    if [[ ${HAVE_CORE} -eq 1 ]]; then
      AWS_ACCESS_KEY_ID="${CORE_KEY_ID}" AWS_SECRET_ACCESS_KEY="${CORE_SECRET}" \
        aws --region "${REGION}" "$@"
    else
      aws --region "${REGION}" --profile hyperbrain-core "$@"
    fi
  else
    if [[ ${HAVE_SENTINEL} -eq 1 ]]; then
      AWS_ACCESS_KEY_ID="${SENTINEL_KEY_ID}" AWS_SECRET_ACCESS_KEY="${SENTINEL_SECRET}" \
        aws --region "${REGION}" "$@"
    else
      aws --region "${REGION}" --profile event-sentinel "$@"
    fi
  fi
}

expect_allow() {
  local label="$1" role="$2"; shift 2
  check "${label} [allow]"
  if aws_as "${role}" "$@" >/dev/null 2>&1; then ok
  else fail "expected allow, got denied"; fi
}

expect_deny() {
  local label="$1" role="$2"; shift 2
  check "${label} [deny]"
  local err
  err=$(aws_as "${role}" "$@" 2>&1 || true)
  if echo "${err}" | grep -qE "AccessDenied|not authorized|AuthorizationError"; then denied
  else fail "expected AccessDenied, got: $(echo "${err}" | head -1)"; fi
}

# ── hyperbrain-core-sqs: acceso completo a las 6 colas ────────────────────────
echo "── hyperbrain-core-sqs ──"
if [[ ${HAVE_CORE} -eq 0 ]]; then
  echo "  SKIP — pasar CORE_KEY_ID y CORE_SECRET (o perfil 'hyperbrain-core')"
  SKIP=$((SKIP+5))
else
  expect_allow "SendMessage   sync-events.fifo" core \
    sqs send-message \
      --queue-url "${BASE}/sync-events.fifo" \
      --message-body '{"source":"iam-test"}' \
      --message-group-id "iam-test" \
      --message-deduplication-id "core-sync-${TS}"

  expect_allow "SendMessage   core-events" core \
    sqs send-message \
      --queue-url "${BASE}/core-events" \
      --message-body '{"source":"iam-test"}'

  expect_allow "SendMessage   ia-jobs" core \
    sqs send-message \
      --queue-url "${BASE}/ia-jobs" \
      --message-body '{"source":"iam-test"}'

  expect_allow "ReceiveMessage sync-events-dlq.fifo" core \
    sqs receive-message \
      --queue-url "${BASE}/sync-events-dlq.fifo" \
      --max-number-of-messages 1

  expect_allow "GetQueueAttributes core-events-dlq" core \
    sqs get-queue-attributes \
      --queue-url "${BASE}/core-events-dlq" \
      --attribute-names All
fi

echo ""
echo "── event-sentinel-api-sqs ──"
if [[ ${HAVE_SENTINEL} -eq 0 ]]; then
  echo "  SKIP — pasar SENTINEL_KEY_ID y SENTINEL_SECRET (o perfil 'event-sentinel')"
  SKIP=$((SKIP+4))
else
  expect_allow "SendMessage   sync-events.fifo" sentinel \
    sqs send-message \
      --queue-url "${BASE}/sync-events.fifo" \
      --message-body '{"source":"iam-test"}' \
      --message-group-id "iam-test" \
      --message-deduplication-id "sentinel-sync-${TS}"

  expect_deny  "SendMessage   core-events      " sentinel \
    sqs send-message \
      --queue-url "${BASE}/core-events" \
      --message-body '{"source":"iam-test"}'

  expect_deny  "SendMessage   ia-jobs          " sentinel \
    sqs send-message \
      --queue-url "${BASE}/ia-jobs" \
      --message-body '{"source":"iam-test"}'

  expect_deny  "ReceiveMessage sync-events-dlq  " sentinel \
    sqs receive-message \
      --queue-url "${BASE}/sync-events-dlq.fifo" \
      --max-number-of-messages 1
fi

echo ""
echo "Resultado: ${PASS} pasaron, ${FAIL} fallaron, ${SKIP} saltados"
[[ ${FAIL} -eq 0 ]] \
  && echo "✓ Políticas IAM correctas" && exit 0 \
  || echo "✗ Revisar terraform/sqs/iam.tf y re-aplicar" && exit 1
