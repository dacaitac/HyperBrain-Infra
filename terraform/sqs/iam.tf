# Access keys are NOT managed by Terraform to keep secrets out of state.
# After apply, create keys manually:
#   aws iam create-access-key --user-name <username>
# Store the resulting key in SOPS:
#   sops secrets.enc.env  (add AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)

# ── HyperBrain-core ───────────────────────────────────────────────────────────
# Consumes sync-events.fifo, apple-commands-results.fifo and user-commands.fifo;
# produces to apple-commands.fifo; full access to its own domain queues
# (ADR-001, ADR-010, HU-09c, HU-01b).

resource "aws_iam_user" "hyperbrain_core" {
  name = "hyperbrain-core-sqs"
  tags = local.common_tags
}

resource "aws_iam_policy" "hyperbrain_core_sqs" {
  name        = "hyperbrain-core-sqs"
  description = "Least-privilege SQS access for HyperBrain-core (ADR-001, ADR-010)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OwnQueuesFullAccess"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = [
          aws_sqs_queue.core_events.arn,
          aws_sqs_queue.ia_jobs.arn,
          aws_sqs_queue.core_events_dlq.arn,
          aws_sqs_queue.ia_jobs_dlq.arn,
        ]
      },
      {
        Sid    = "InboundConsume"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:ChangeMessageVisibility",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = [
          aws_sqs_queue.sync_events.arn,
          aws_sqs_queue.apple_commands_results.arn,
          aws_sqs_queue.user_commands.arn,
          aws_sqs_queue.sync_events_dlq.arn,
          aws_sqs_queue.apple_commands_results_dlq.arn,
          aws_sqs_queue.apple_commands_dlq.arn,
          aws_sqs_queue.user_commands_dlq.arn,
        ]
      },
      {
        Sid    = "AppleCommandsProduce"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = [aws_sqs_queue.apple_commands.arn]
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "hyperbrain_core_sqs" {
  user       = aws_iam_user.hyperbrain_core.name
  policy_arn = aws_iam_policy.hyperbrain_core_sqs.arn
}

# ── SentinelAPI (Mac Mini) ────────────────────────────────────────────────────
# Produces Apple change events to sync-events.fifo, write-command results to
# apple-commands-results.fifo and user commands (iOS shortcuts: replan trigger,
# Sleep Score) to user-commands.fifo (HU-01b #66); consumes write commands from
# apple-commands.fifo.
# The directions use separate queues (competing-consumers: SentinelAPI must not
# receive from sync-events.fifo, which the Core consumes). TD-03 #21, ADR-010.

resource "aws_iam_user" "event_sentinel_api" {
  name = "event-sentinel-api-sqs"
  tags = local.common_tags
}

resource "aws_iam_policy" "event_sentinel_api_sqs" {
  name        = "event-sentinel-api-sqs"
  description = "Least-privilege SQS access for SentinelAPI (ADR-001, TD-03)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SyncEventsAndResultsProduce"
        Effect = "Allow"
        Action = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
        Resource = [
          aws_sqs_queue.sync_events.arn,
          aws_sqs_queue.apple_commands_results.arn,
          aws_sqs_queue.user_commands.arn,
        ]
      },
      {
        Sid      = "AppleCommandsConsume"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.apple_commands.arn]
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "event_sentinel_api_sqs" {
  user       = aws_iam_user.event_sentinel_api.name
  policy_arn = aws_iam_policy.event_sentinel_api_sqs.arn
}
