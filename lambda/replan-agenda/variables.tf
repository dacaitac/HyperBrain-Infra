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

variable "replan_token_param" {
  description = "SSM SecureString parameter holding the bearer token checked in the X-HyperBrain-Token header (created manually, never in Terraform state)"
  type        = string
  default     = "/hyperbrain/replan/token"
}
