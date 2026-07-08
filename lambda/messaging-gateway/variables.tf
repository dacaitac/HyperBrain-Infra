variable "aws_region" {
  description = "AWS region where the Lambda is provisioned (must match terraform/sqs)"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment label applied to all resource tags"
  type        = string
  default     = "prod"
}

variable "messaging_token_param" {
  description = "SSM SecureString parameter holding the bearer token that OpenClaw sends in X-HyperBrain-Token (created manually via aws ssm put-parameter, never in state)"
  type        = string
  default     = "/hyperbrain/messaging/token"
}
