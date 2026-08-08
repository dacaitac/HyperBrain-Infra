# Access keys are NOT managed by Terraform to keep secrets out of state (same
# convention as terraform/sqs/iam.tf). After apply, create keys manually:
#   aws iam create-access-key --user-name hyperbrain-backup-offsite --profile hb-admin
# Store the resulting key pair as the [hb-offsite] stanza of the rclone.conf
# that goes into secrets.enc.env (RCLONE_CONF_B64) — see k8s/README.md and
# docs/backup-restore.md. Do NOT reuse these credentials anywhere else.

resource "aws_iam_user" "hb_offsite_backup" {
  name = "hyperbrain-backup-offsite"
  tags = local.common_tags
}

resource "aws_iam_policy" "hb_offsite_backup" {
  name        = "hyperbrain-backup-offsite"
  description = "Least-privilege access for pg-dump-offsite: this bucket only, no delete (Infra#28)"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListOwnBucket"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.hb_offsite.arn]
      },
      {
        # PutObject + GetObject (no DeleteObject): the CronJob only needs to
        # write, and the restore drill needs to read. Deletion of old objects
        # is handled by the lifecycle rule above, not by the backup principal —
        # a compromised/misbehaving job credential cannot erase existing backups.
        Sid      = "ReadWriteObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["${aws_s3_bucket.hb_offsite.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_user_policy_attachment" "hb_offsite_backup" {
  user       = aws_iam_user.hb_offsite_backup.name
  policy_arn = aws_iam_policy.hb_offsite_backup.arn
}
