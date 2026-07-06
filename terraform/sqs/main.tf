terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Local backend — terraform.tfstate is gitignored.
  # Encrypted backup: sops --encrypt --age <PUBLIC_KEY> terraform.tfstate > terraform.tfstate.enc
  backend "local" {}
}

provider "aws" {
  region = var.aws_region
}

# ── DLQs ──────────────────────────────────────────────────────────────────────
# DLQs must exist before main queues reference their ARNs in redrive policies.

resource "aws_sqs_queue" "sync_events_dlq" {
  name                        = "sync-events-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  message_retention_seconds   = 1209600 # 14 days
  visibility_timeout_seconds  = 30

  tags = local.common_tags
}

resource "aws_sqs_queue" "apple_commands_dlq" {
  name                        = "apple-commands-dlq.fifo"
  fifo_queue                  = true
  content_based_deduplication = false
  message_retention_seconds   = 1209600 # 14 days
  visibility_timeout_seconds  = 30

  tags = local.common_tags
}

resource "aws_sqs_queue" "core_events_dlq" {
  name                       = "core-events-dlq"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 30

  tags = local.common_tags
}

resource "aws_sqs_queue" "ia_jobs_dlq" {
  name                       = "ia-jobs-dlq"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 120

  tags = local.common_tags
}

# ── Main queues ───────────────────────────────────────────────────────────────

resource "aws_sqs_queue" "sync_events" {
  name                        = "sync-events.fifo"
  fifo_queue                  = true
  content_based_deduplication = false # Deduplication via explicit MessageDeduplicationId = message_id
  message_retention_seconds   = 1209600
  visibility_timeout_seconds  = 30

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.sync_events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.common_tags
}

resource "aws_sqs_queue" "apple_commands" {
  name                        = "apple-commands.fifo"
  fifo_queue                  = true
  content_based_deduplication = false # Deduplication via explicit MessageDeduplicationId
  message_retention_seconds   = 1209600
  visibility_timeout_seconds  = 30

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.apple_commands_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.common_tags
}

resource "aws_sqs_queue" "core_events" {
  name                       = "core-events"
  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 30

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.core_events_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.common_tags
}

resource "aws_sqs_queue" "ia_jobs" {
  name                       = "ia-jobs"
  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 120

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ia_jobs_dlq.arn
    maxReceiveCount     = 3
  })

  tags = local.common_tags
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  common_tags = {
    project     = "hyperbrain"
    environment = var.environment
    managed_by  = "terraform"
  }
}
