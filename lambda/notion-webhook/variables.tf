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

variable "webhook_secret_param" {
  description = "SSM SecureString parameter holding the Notion subscription HMAC verification token (created manually, never in state)"
  type        = string
  default     = "/hyperbrain/notion/webhook-secret"
}

variable "automation_token_param" {
  description = "SSM SecureString parameter holding the shared bearer token that Notion DB automations send in the X-HyperBrain-Token header (created manually, never in state)"
  type        = string
  default     = "/hyperbrain/notion/automation-token"
}
