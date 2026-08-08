output "bucket_name" {
  description = "S3 bucket name — this is the rclone.conf hb-offsite bucket/root, and BACKUP_OFFSITE_PATH is a prefix inside it"
  value       = aws_s3_bucket.hb_offsite.id
}

output "iam_user" {
  description = "IAM username for the off-site backup principal — create access keys manually via AWS CLI"
  value       = aws_iam_user.hb_offsite_backup.name
}
