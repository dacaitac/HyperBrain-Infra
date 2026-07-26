#!/bin/sh
# Creates the 12 SQS queues defined in ADR-001 (+ apple-commands-results ADR-010,
# + user-commands HU-01b #66).
# Idempotent: create-queue returns existing URL if queue already exists.
# Runs inside the sqs-init container (amazon/aws-cli) after LocalStack is healthy.
set -eu

ENDPOINT="${AWS_ENDPOINT_URL:-http://localstack:4566}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ACCOUNT="000000000000"

create_queue() {
  local name="$1"; shift
  if aws --endpoint-url="${ENDPOINT}" sqs create-queue --queue-name "${name}" "$@" > /dev/null 2>&1; then
    echo "  created  ${name}"
  else
    echo "  exists   ${name}"
  fi
}

set_redrive() {
  local queue="$1"
  local dlq="$2"
  local dlq_arn="arn:aws:sqs:${REGION}:${ACCOUNT}:${dlq}"
  local queue_url="${ENDPOINT}/${ACCOUNT}/${queue}"
  local tmp="/tmp/redrive_${queue}.json"

  cat > "${tmp}" << EOF
{"RedrivePolicy":"{\"deadLetterTargetArn\":\"${dlq_arn}\",\"maxReceiveCount\":\"3\"}"}
EOF

  aws --endpoint-url="${ENDPOINT}" sqs set-queue-attributes \
    --queue-url "${queue_url}" \
    --attributes "file://${tmp}" > /dev/null

  rm -f "${tmp}"
}

echo "=== Creating SQS queues ==="

# DLQs must be created before main queues reference their ARNs
create_queue "sync-events-dlq.fifo" --attributes "FifoQueue=true,ContentBasedDeduplication=false,MessageRetentionPeriod=1209600,VisibilityTimeout=30"
create_queue "apple-commands-dlq.fifo" --attributes "FifoQueue=true,ContentBasedDeduplication=false,MessageRetentionPeriod=1209600,VisibilityTimeout=30"
create_queue "apple-commands-results-dlq.fifo" --attributes "FifoQueue=true,ContentBasedDeduplication=false,MessageRetentionPeriod=1209600,VisibilityTimeout=30"
create_queue "user-commands-dlq.fifo" --attributes "FifoQueue=true,ContentBasedDeduplication=false,MessageRetentionPeriod=1209600,VisibilityTimeout=30"
create_queue "core-events-dlq" --attributes "MessageRetentionPeriod=1209600,VisibilityTimeout=30"
create_queue "ia-jobs-dlq" --attributes "MessageRetentionPeriod=1209600,VisibilityTimeout=120"

# Main queues — FIFO queues use explicit MessageDeduplicationId (ContentBasedDeduplication=false)
create_queue "sync-events.fifo" --attributes "FifoQueue=true,ContentBasedDeduplication=false,MessageRetentionPeriod=1209600,VisibilityTimeout=30"
create_queue "apple-commands.fifo" --attributes "FifoQueue=true,ContentBasedDeduplication=false,MessageRetentionPeriod=1209600,VisibilityTimeout=30"
create_queue "apple-commands-results.fifo" --attributes "FifoQueue=true,ContentBasedDeduplication=false,MessageRetentionPeriod=1209600,VisibilityTimeout=30"
create_queue "user-commands.fifo" --attributes "FifoQueue=true,ContentBasedDeduplication=false,MessageRetentionPeriod=1209600,VisibilityTimeout=30"
create_queue "core-events" --attributes "MessageRetentionPeriod=1209600,VisibilityTimeout=30"
create_queue "ia-jobs" --attributes "MessageRetentionPeriod=1209600,VisibilityTimeout=120"

# Attach redrive policies (DLQs already exist, ARNs are deterministic in LocalStack)
set_redrive "sync-events.fifo"    "sync-events-dlq.fifo"
set_redrive "apple-commands.fifo" "apple-commands-dlq.fifo"
set_redrive "apple-commands-results.fifo" "apple-commands-results-dlq.fifo"
set_redrive "user-commands.fifo"  "user-commands-dlq.fifo"
set_redrive "core-events"         "core-events-dlq"
set_redrive "ia-jobs"             "ia-jobs-dlq"

echo ""
COUNT=$(aws --endpoint-url="${ENDPOINT}" sqs list-queues --query 'length(QueueUrls)' --output text 2>/dev/null || echo "?")
echo "=== ${COUNT}/12 queues active ==="
