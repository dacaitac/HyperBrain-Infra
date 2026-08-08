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

# ── hb-offsite bucket (Infra#28) ───────────────────────────────────────────────
# Dedicated off-site target for pg-dump-offsite (k8s/base/backup/pg-dump-offsite-cronjob.yaml).
# Deliberately NOT one of Daniel's personal rclone remotes ([unacional]/[i7_danielcc]) —
# see the root-cause note in docs/backup-restore.md and Infra#28. HyperBrain-owned,
# scoped IAM, no other workload touches this bucket.

resource "aws_s3_bucket" "hb_offsite" {
  bucket = "hyperbrain-backup-offsite-${var.bucket_suffix}"

  tags = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "hb_offsite" {
  bucket = aws_s3_bucket.hb_offsite.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "hb_offsite" {
  bucket = aws_s3_bucket.hb_offsite.id

  versioning_configuration {
    # Protects against overwrite/corruption of the daily object — cheap given
    # MVP volume (one small .dump.age object per day).
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "hb_offsite" {
  bucket = aws_s3_bucket.hb_offsite.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "hb_offsite" {
  bucket = aws_s3_bucket.hb_offsite.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# ── Locals ────────────────────────────────────────────────────────────────────

locals {
  common_tags = {
    project     = "hyperbrain"
    environment = var.environment
    managed_by  = "terraform"
    purpose     = "backup-offsite"
  }
}
