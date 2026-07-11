# Queue URLs — set these as SQS_*_URL in .env after apply.
# LocalStack equivalent: http://localhost:4566/000000000000/<queue-name>

output "sync_events_url" {
  description = "URL of sync-events.fifo (SQS_SYNC_EVENTS_URL)"
  value       = aws_sqs_queue.sync_events.url
}

output "apple_commands_url" {
  description = "URL of apple-commands.fifo (SQS_APPLE_COMMANDS_URL / APPLE_COMMANDS_QUEUE_URL)"
  value       = aws_sqs_queue.apple_commands.url
}

output "apple_commands_results_url" {
  description = "URL of apple-commands-results.fifo (SQS_APPLE_COMMANDS_RESULTS_URL / APPLE_COMMANDS_RESULTS_QUEUE_URL)"
  value       = aws_sqs_queue.apple_commands_results.url
}

output "user_commands_url" {
  description = "URL of user-commands.fifo (SQS_USER_COMMANDS_URL)"
  value       = aws_sqs_queue.user_commands.url
}

output "core_events_url" {
  description = "URL of core-events (SQS_CORE_EVENTS_URL)"
  value       = aws_sqs_queue.core_events.url
}

output "ia_jobs_url" {
  description = "URL of ia-jobs (SQS_IA_JOBS_URL)"
  value       = aws_sqs_queue.ia_jobs.url
}

output "sync_events_arn" {
  description = "ARN of sync-events.fifo"
  value       = aws_sqs_queue.sync_events.arn
}

output "apple_commands_arn" {
  description = "ARN of apple-commands.fifo"
  value       = aws_sqs_queue.apple_commands.arn
}

output "apple_commands_results_arn" {
  description = "ARN of apple-commands-results.fifo"
  value       = aws_sqs_queue.apple_commands_results.arn
}

output "user_commands_arn" {
  description = "ARN of user-commands.fifo"
  value       = aws_sqs_queue.user_commands.arn
}

output "core_events_arn" {
  description = "ARN of core-events"
  value       = aws_sqs_queue.core_events.arn
}

output "ia_jobs_arn" {
  description = "ARN of ia-jobs"
  value       = aws_sqs_queue.ia_jobs.arn
}

output "hyperbrain_core_iam_user" {
  description = "IAM username for HyperBrain-core — create access keys manually via AWS CLI"
  value       = aws_iam_user.hyperbrain_core.name
}

output "event_sentinel_api_iam_user" {
  description = "IAM username for EventSentinelAPI — create access keys manually via AWS CLI"
  value       = aws_iam_user.event_sentinel_api.name
}
