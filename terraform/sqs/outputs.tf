# Queue URLs — set these as SQS_*_URL in .env after apply.
# LocalStack equivalent: http://localhost:4566/000000000000/<queue-name>

output "sync_events_url" {
  description = "URL of sync-events.fifo (SQS_SYNC_EVENTS_URL)"
  value       = aws_sqs_queue.sync_events.url
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
