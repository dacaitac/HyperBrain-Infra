# terraform/backup-offsite — dedicated off-site bucket for pg-dump-offsite

Drafted for Infra#28 (backup off-site was broken: `BACKUP_RCLONE_REMOTE=hb-offsite` pointed at a
remote that was never created — see the root-cause note in `docs/backup-restore.md`). **Applied
2026-08-08** — `bucket_name = hyperbrain-backup-offsite-<account-id>`, IAM user
`hyperbrain-backup-offsite`. Terraform apply is reserved to Daniel (`infra-claude.md`); state stays
local and gitignored, not committed.

## What this provisions

- `aws_s3_bucket.hb_offsite` — dedicated bucket, not one of Daniel's personal rclone remotes.
  Versioned, SSE-AES256, public access fully blocked, noncurrent versions expire after 90 days.
- `aws_iam_user.hb_offsite_backup` + scoped policy: `s3:ListBucket` on the bucket,
  `s3:PutObject`/`s3:GetObject` on its objects — **no `DeleteObject`**, so a leaked credential from
  the CronJob cannot erase existing backups.

## Apply (Daniel, out of band)

```bash
aws login --profile hb-admin   # SSO
export AWS_PROFILE=hb-admin

cd terraform/backup-offsite
cp terraform.tfvars.example terraform.tfvars   # set bucket_suffix (e.g. the AWS account ID)
terraform init
terraform plan     # review before apply
terraform apply

# Access keys are not in Terraform state (same convention as terraform/sqs):
aws iam create-access-key --user-name hyperbrain-backup-offsite --profile hb-admin
```

## Wire it into rclone.conf / secrets.enc.env

Add **only** the `[hb-offsite]` stanza to the `rclone.conf` that gets base64'd into
`RCLONE_CONF_B64` (see `k8s/README.md` — the secret must not carry Daniel's personal remotes):

```ini
[hb-offsite]
type = s3
provider = AWS
env_auth = false
access_key_id = <from create-access-key>
secret_access_key = <from create-access-key>
region = us-east-1
```

Then follow `k8s/README.md#regenerating-secretsencenv-daniel-out-of-band` to rebuild
`secrets.enc.env` and regenerate the `hyperbrain-secrets` Secret via the CD flow (not
`kubectl edit`/`kubectl create secret` by hand).
