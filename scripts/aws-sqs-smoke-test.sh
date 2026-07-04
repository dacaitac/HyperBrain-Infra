#!/usr/bin/env bash
# AWS SQS smoke test — run on daniel-ubuntu after `terraform apply`.
# Validates queues, IAM, and connectivity end-to-end.
# Requires: aws CLI configured with HyperBrain-core credentials.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PASS=0; FAIL=0

check() { echo -n "  → $1... "; }
ok()    { echo "✓"; PASS=$((PASS+1)); }
fail()  { echo "✗  $1"; FAIL=$((FAIL+1)); }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BASE="https://sqs.${REGION}.amazonaws.com/${ACCOUNT}"

SYNC_URL="${BASE}/sync-events.fifo"
CORE_URL="${BASE}/core-events"
IA_URL="${BASE}/ia-jobs"

echo "=== HyperBrain AWS SQS Smoke Test ==="
echo "Account: ${ACCOUNT} | Region: ${REGION}"
echo ""

# 1. sync-events.fifo
check "Send → sync-events.fifo"
MSG_ID=$(aws sqs send-message \
  --queue-url "${SYNC_URL}" \
  --message-body '{"source":"smoke-test","type":"REMINDER_CREATED"}' \
  --message-group-id "smoke-test" \
  --message-deduplication-id "smoke-$(date +%s%N)" \
  --query MessageId --output text)
ok
echo "     MessageId: ${MSG_ID}"

check "Receive ← sync-events.fifo"
RECEIPT=$(aws sqs receive-message \
  --queue-url "${SYNC_URL}" \
  --max-number-of-messages 1 \
  --wait-time-seconds 5 \
  --query 'Messages[0].ReceiptHandle' --output text 2>/dev/null || echo "None")
[ "${RECEIPT}" != "None" ] && [ -n "${RECEIPT}" ] && ok || fail "No message received"

if [ "${RECEIPT}" != "None" ] && [ -n "${RECEIPT}" ]; then
  aws sqs delete-message --queue-url "${SYNC_URL}" --receipt-handle "${RECEIPT}" > /dev/null
fi

# 2. core-events
check "Send → core-events"
aws sqs send-message \
  --queue-url "${CORE_URL}" \
  --message-body '{"source":"smoke-test","type":"TASK_CREATED"}' \
  --query MessageId --output text > /dev/null && ok || fail "Send failed"

check "Receive ← core-events"
RECEIPT=$(aws sqs receive-message \
  --queue-url "${CORE_URL}" \
  --max-number-of-messages 1 \
  --wait-time-seconds 5 \
  --query 'Messages[0].ReceiptHandle' --output text 2>/dev/null || echo "None")
[ "${RECEIPT}" != "None" ] && [ -n "${RECEIPT}" ] && ok || fail "No message received"

if [ "${RECEIPT}" != "None" ] && [ -n "${RECEIPT}" ]; then
  aws sqs delete-message --queue-url "${CORE_URL}" --receipt-handle "${RECEIPT}" > /dev/null
fi

# 3. ia-jobs
check "Send → ia-jobs"
aws sqs send-message \
  --queue-url "${IA_URL}" \
  --message-body '{"source":"smoke-test","type":"PRIORITIZE_TASKS"}' \
  --query MessageId --output text > /dev/null && ok || fail "Send failed"

check "Receive ← ia-jobs"
RECEIPT=$(aws sqs receive-message \
  --queue-url "${IA_URL}" \
  --max-number-of-messages 1 \
  --wait-time-seconds 5 \
  --query 'Messages[0].ReceiptHandle' --output text 2>/dev/null || echo "None")
[ "${RECEIPT}" != "None" ] && [ -n "${RECEIPT}" ] && ok || fail "No message received"

if [ "${RECEIPT}" != "None" ] && [ -n "${RECEIPT}" ]; then
  aws sqs delete-message --queue-url "${IA_URL}" --receipt-handle "${RECEIPT}" > /dev/null
fi

echo ""
echo "Resultado: ${PASS} pasaron, ${FAIL} fallaron"
[ ${FAIL} -eq 0 ] && echo "✓ Colas AWS SQS operativas" && exit 0 \
                  || echo "✗ Revisar credenciales IAM y topología de colas" && exit 1
