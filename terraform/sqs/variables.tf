variable "aws_region" {
  description = "AWS region where SQS queues are provisioned"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment label applied to all resource tags"
  type        = string
  default     = "prod"
}
