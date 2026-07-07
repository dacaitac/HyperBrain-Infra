# Function URL — set as NOTION_WEBHOOK_FUNCTION_URL in .env (SOPS) after apply
# and register it as the webhook endpoint in the Notion integration (#42).

output "function_url" {
  description = "Public HTTPS endpoint for Notion webhook deliveries (NOTION_WEBHOOK_FUNCTION_URL)"
  value       = aws_lambda_function_url.notion_webhook.function_url
}

output "function_name" {
  description = "Lambda function name (CloudWatch log group: /aws/lambda/<name>)"
  value       = aws_lambda_function.notion_webhook.function_name
}

output "role_arn" {
  description = "Execution role ARN of the webhook Lambda"
  value       = aws_iam_role.lambda.arn
}
