# Function URL — set as REPLAN_AGENDA_FUNCTION_URL in .env (SOPS) after apply.

output "function_url" {
  description = "Public HTTPS endpoint to trigger an agenda replan (REPLAN_AGENDA_FUNCTION_URL)"
  value       = aws_lambda_function_url.replan_agenda.function_url
}

output "function_name" {
  description = "Lambda function name (CloudWatch log group: /aws/lambda/<name>)"
  value       = aws_lambda_function.replan_agenda.function_name
}

output "role_arn" {
  description = "Execution role ARN of the replan-agenda Lambda"
  value       = aws_iam_role.lambda.arn
}
