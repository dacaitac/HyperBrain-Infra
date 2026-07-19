#!/usr/bin/env bash
# =============================================================================
# purge-sqs.sh — F5' cleanup gate, queue side (ADR-021)
#
# Purges the 12 production queues (6 main + 6 DLQs, names from
# terraform/sqs/main.tf) and verifies ApproximateNumberOfMessages == 0.
# AWS allows ONE purge per queue per 60s and the purge itself may take up to
# 60s — the script retries on PurgeQueueInProgress and polls until drained.
#
# Usage:
#   scripts/k8s/purge-sqs.sh              # DRY-RUN (default): list + counts
#   scripts/k8s/purge-sqs.sh --execute    # actually purge + verify
#
# Env: standard AWS CLI auth (AWS_PROFILE / exported credentials). Purge
# requires sqs:PurgeQueue — use the hb-admin profile, not the runtime user.
# =============================================================================
set -euo pipefail

MODE="dry-run"
[[ "${1:-}" == "--execute" ]] && MODE="execute"

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI is required" >&2; exit 1; }

# Keep in sync with terraform/sqs/main.tf (and ADR-001)
QUEUES=(
  sync-events.fifo
  sync-events-dlq.fifo
  apple-commands.fifo
  apple-commands-dlq.fifo
  apple-commands-results.fifo
  apple-commands-results-dlq.fifo
  user-commands.fifo
  user-commands-dlq.fifo
  core-events
  core-events-dlq
  ia-jobs
  ia-jobs-dlq
)

log() { echo "[purge-sqs] $*"; }

msg_count() { # $1 = queue url
  aws sqs get-queue-attributes --queue-url "$1" \
    --attribute-names ApproximateNumberOfMessages \
    --query 'Attributes.ApproximateNumberOfMessages' --output text
}

log "mode: ${MODE} — ${#QUEUES[@]} queues"
failures=0

for q in "${QUEUES[@]}"; do
  if ! url="$(aws sqs get-queue-url --queue-name "${q}" --query QueueUrl --output text 2>/dev/null)"; then
    log "ERROR: queue not found: ${q}"
    failures=$((failures+1))
    continue
  fi
  count="$(msg_count "${url}")"
  if [[ "${MODE}" == "dry-run" ]]; then
    log "would purge ${q} (approx ${count} messages)"
    continue
  fi

  log "purging ${q} (approx ${count} messages)"
  # Retry on PurgeQueueInProgress (max 1 purge per 60s per queue)
  attempt=0
  until aws sqs purge-queue --queue-url "${url}" 2>/tmp/purge-sqs.err; do
    if grep -q "PurgeQueueInProgress" /tmp/purge-sqs.err && [[ ${attempt} -lt 2 ]]; then
      attempt=$((attempt+1))
      log "  purge already in progress for ${q}; waiting 65s (attempt ${attempt}/2)"
      sleep 65
    else
      log "  ERROR purging ${q}: $(cat /tmp/purge-sqs.err)"
      failures=$((failures+1))
      continue 2
    fi
  done

  # Verify drained: purge can take up to 60s to complete
  drained=false
  for _ in $(seq 1 12); do
    count="$(msg_count "${url}")"
    if [[ "${count}" == "0" ]]; then
      drained=true
      break
    fi
    sleep 10
  done
  if [[ "${drained}" == "true" ]]; then
    log "  OK: ${q} is empty"
  else
    log "  ERROR: ${q} still reports ${count} messages after 120s"
    failures=$((failures+1))
  fi
done

echo
if [[ "${MODE}" == "dry-run" ]]; then
  log "dry-run complete — re-run with --execute to purge (missing queues: ${failures})"
  [[ ${failures} -eq 0 ]] || exit 1
else
  if [[ ${failures} -eq 0 ]]; then
    log "all ${#QUEUES[@]} queues purged and verified empty"
  else
    log "COMPLETED WITH ${failures} FAILURES"
    exit 1
  fi
fi
