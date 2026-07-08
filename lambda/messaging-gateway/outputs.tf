# Function URL — configure as MESSAGING_GATEWAY_URL in OpenClaw settings after apply.

output "function_url" {
  description = "Public HTTPS endpoint for OpenClaw/WhatsApp message deliveries (MESSAGING_GATEWAY_URL)"
  value       = aws_lambda_function_url.messaging_gateway.function_url
}

output "function_name" {
  description = "Lambda function name (CloudWatch log group: /aws/lambda/<name>)"
  value       = aws_lambda_function.messaging_gateway.function_name
}

output "role_arn" {
  description = "Execution role ARN of the messaging gateway Lambda"
  value       = aws_iam_role.lambda.arn
}
