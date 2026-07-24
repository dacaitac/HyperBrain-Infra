# Function URL — set as TELEMETRY_GATEWAY_FUNCTION_URL in .env (SOPS) after apply.

output "function_url" {
  description = "Public HTTPS endpoint for iOS telemetry uploads (TELEMETRY_GATEWAY_FUNCTION_URL)"
  value       = aws_lambda_function_url.telemetry_gateway.function_url
}

output "function_name" {
  description = "Lambda function name (CloudWatch log group: /aws/lambda/<name>)"
  value       = aws_lambda_function.telemetry_gateway.function_name
}

output "role_arn" {
  description = "Execution role ARN of the telemetry-gateway Lambda"
  value       = aws_iam_role.lambda.arn
}
