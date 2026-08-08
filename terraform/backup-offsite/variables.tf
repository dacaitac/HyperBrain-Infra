variable "aws_region" {
  description = "AWS region where the off-site backup bucket is provisioned"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment label applied to all resource tags"
  type        = string
  default     = "prod"
}

variable "bucket_suffix" {
  description = <<-EOT
    Suffix to make the bucket name globally unique (S3 bucket names are a
    global namespace). Use a short, stable, non-guessable value — e.g. the
    AWS account ID or a random hex string. Set via terraform.tfvars (gitignored).
  EOT
  type        = string
}
