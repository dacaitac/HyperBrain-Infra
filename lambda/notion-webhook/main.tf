terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
  # Local backend — terraform.tfstate is gitignored, same as terraform/sqs.
  backend "local" {}
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# Queue provisioned by terraform/sqs (separate state) — looked up by name to
# avoid cross-state coupling.
data "aws_sqs_queue" "sync_events" {
  name = "sync-events.fifo"
}

data "archive_file" "handler" {
  type        = "zip"
  source_file = "${path.module}/handler.py"
  output_path = "${path.module}/.build/handler.zip"
}

# ── IAM ───────────────────────────────────────────────────────────────────────
# Least privilege: send to sync-events.fifo only, read the webhook secret from
# SSM, write its own CloudWatch logs. The secret value itself is never in state
# (created manually via `aws ssm put-parameter`, see README).

resource "aws_iam_role" "lambda" {
  name = "notion-webhook-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy" "lambda" {
  name = "notion-webhook-lambda"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SyncEventsProduce"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
        Resource = [data.aws_sqs_queue.sync_events.arn]
      },
      {
        Sid      = "WebhookSecretRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.webhook_secret_param}"]
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
      }
    ]
  })
}

# ── Lambda ────────────────────────────────────────────────────────────────────

resource "aws_lambda_function" "notion_webhook" {
  function_name    = "notion-webhook-receiver"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  architectures    = ["arm64"]
  handler          = "handler.lambda_handler"
  filename         = data.archive_file.handler.output_path
  source_code_hash = data.archive_file.handler.output_base64sha256
  timeout          = 10
  memory_size      = 128

  environment {
    variables = {
      QUEUE_URL            = data.aws_sqs_queue.sync_events.url
      WEBHOOK_SECRET_PARAM = var.webhook_secret_param
    }
  }

  tags = local.common_tags
}

# Public HTTPS entry point for Notion deliveries. Auth NONE by design: request
# authenticity is enforced by the HMAC signature check inside the handler
# (ADR-011 — daniel-ubuntu never exposes a public port).
resource "aws_lambda_function_url" "notion_webhook" {
  function_name      = aws_lambda_function.notion_webhook.function_name
  authorization_type = "NONE"
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  common_tags = {
    project     = "hyperbrain"
    environment = var.environment
    managed_by  = "terraform"
  }
}
