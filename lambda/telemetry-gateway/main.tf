terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      # >= 6.x: aws_lambda_permission.invoked_via_function_url (public Function
      # URLs require the extra InvokeFunction grant since Oct 2025)
      source  = "hashicorp/aws"
      version = "~> 6.0"
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
data "aws_sqs_queue" "telemetry_events" {
  name = "telemetry-events"
}

data "archive_file" "handler" {
  type        = "zip"
  source_file = "${path.module}/handler.py"
  output_path = "${path.module}/.build/handler.zip"
}

# ── IAM ───────────────────────────────────────────────────────────────────────
# Least privilege: send to telemetry-events only, read the bearer token from
# SSM (SecureString — value never in Terraform state), write CloudWatch logs.

resource "aws_iam_role" "lambda" {
  name = "telemetry-gateway-lambda"
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
  name = "telemetry-gateway-lambda"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TelemetryEventsProduce"
        Effect = "Allow"
        Action = [
          "sqs:SendMessage",
          "sqs:GetQueueAttributes",
        ]
        Resource = [data.aws_sqs_queue.telemetry_events.arn]
      },
      {
        Sid    = "TelemetryTokenRead"
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.telemetry_token_param}",
        ]
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

resource "aws_lambda_function" "telemetry_gateway" {
  function_name    = "telemetry-gateway"
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
      QUEUE_URL             = data.aws_sqs_queue.telemetry_events.url
      TELEMETRY_TOKEN_PARAM = var.telemetry_token_param
    }
  }

  tags = local.common_tags
}

# Public HTTPS entry point for iOS telemetry uploads. Auth NONE by design:
# request authenticity is enforced inside the handler (bearer token in the
# X-HyperBrain-Token header checked via constant-time compare against the SSM
# secret).
resource "aws_lambda_function_url" "telemetry_gateway" {
  function_name      = aws_lambda_function.telemetry_gateway.function_name
  authorization_type = "NONE"
}

# authorization_type = NONE still requires an explicit resource-based policy:
# anonymous callers need BOTH lambda:InvokeFunctionUrl and (since Oct 2025)
# lambda:InvokeFunction, or every request gets 403.
resource "aws_lambda_permission" "public_function_url" {
  statement_id           = "AllowPublicFunctionUrlInvoke"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.telemetry_gateway.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# invoked_via_function_url scopes the public InvokeFunction grant to calls
# that arrive through the Function URL — direct API invocation stays denied.
resource "aws_lambda_permission" "public_function_invoke" {
  statement_id             = "AllowPublicFunctionInvokeViaUrl"
  action                   = "lambda:InvokeFunction"
  function_name            = aws_lambda_function.telemetry_gateway.function_name
  principal                = "*"
  invoked_via_function_url = true
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  common_tags = {
    project     = "hyperbrain"
    environment = var.environment
    managed_by  = "terraform"
  }
}
