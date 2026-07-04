#!/usr/bin/env bash
# DLQ redrive — moves messages from a DLQ back to its source queue.
# Run manually when messages are in the DLQ and the underlying issue is fixed.
#
# POLICY — cuándo reintentar vs. purgar:
#   - REINTENTAR: el error fue transitorio (timeout, red, dependencia caída).
#     Corregir la causa raíz primero, luego hacer redrive.
#   - PURGAR: el mensaje es inválido/irrecuperable (schema roto, datos corruptos).
#     ANTES de purgar, registrar payload + log de error en CONTEXT_EVENT (auditoría).
#     Usar `aws sqs purge-queue` solo como último recurso; es irreversible.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BASE="https://sqs.${REGION}.amazonaws.com/${ACCOUNT}"

usage() {
  echo "Usage: $0 <queue-name>"
  echo "  queue-name: sync-events.fifo | core-events | ia-jobs"
  exit 1
}

[ $# -ne 1 ] && usage

QUEUE="$1"
case "${QUEUE}" in
  "sync-events.fifo") DLQ="sync-events-dlq.fifo" ;;
  "core-events")      DLQ="core-events-dlq" ;;
  "ia-jobs")          DLQ="ia-jobs-dlq" ;;
  *) echo "Unknown queue: ${QUEUE}"; usage ;;
esac

SOURCE_URL="${BASE}/${DLQ}"
TARGET_ARN="arn:aws:sqs:${REGION}:${ACCOUNT}/${QUEUE}"

echo "Starting message move: ${DLQ} → ${QUEUE}"
TASK=$(aws sqs start-message-move-task \
  --source-queue-url "${SOURCE_URL}" \
  --destination-queue-url "${BASE}/${QUEUE}" \
  --query TaskHandle --output text)

echo "Task handle: ${TASK}"
echo "Monitor with: aws sqs list-message-move-tasks --source-queue-url ${SOURCE_URL}"
