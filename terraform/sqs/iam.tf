# Access keys are NOT managed by Terraform to keep secrets out of state.
# After apply, create keys manually:
#   aws iam create-access-key --user-name <username>
# Store the resulting key in SOPS:
#   sops secrets.enc.env  (add AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)

# ── HyperBrain-core ───────────────────────────────────────────────────────────
# Full consumer/producer access to all 6 queues (ADR-001).

resource "aws_iam_user" "hyperbrain_core" {
  name = "hyperbrain-core-sqs"
  tags = local.common_tags
}

resource "aws_iam_policy" "hyperbrain_core_sqs" {
  name        = "hyperbrain-core-sqs"
  description = "Least-privilege SQS access for HyperBrain-core (ADR-001)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllQueuesAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [
          aws_sqs_queue.sync_events.arn,
          aws_sqs_queue.core_events.arn,
          aws_sqs_queue.ia_jobs.arn,
          aws_sqs_queue.sync_events_dlq.arn,
          aws_sqs_queue.core_events_dlq.arn,
          aws_sqs_queue.ia_jobs_dlq.arn,
        ]
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "hyperbrain_core_sqs" {
  user       = aws_iam_user.hyperbrain_core.name
  policy_arn = aws_iam_policy.hyperbrain_core_sqs.arn
}

# ── EventSentinelAPI (Mac Mini) ───────────────────────────────────────────────
# Sends iOS events to sync-events.fifo; receives write commands from the same queue.

resource "aws_iam_user" "event_sentinel_api" {
  name = "event-sentinel-api-sqs"
  tags = local.common_tags
}

resource "aws_iam_policy" "event_sentinel_api_sqs" {
  name        = "event-sentinel-api-sqs"
  description = "Least-privilege SQS access for EventSentinelAPI (ADR-001)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SyncEventsAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [aws_sqs_queue.sync_events.arn]
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "event_sentinel_api_sqs" {
  user       = aws_iam_user.event_sentinel_api.name
  policy_arn = aws_iam_policy.event_sentinel_api_sqs.arn
}
