# HyperBrain — Backup & Restore

## Overview

| What | Where | Retention |
|:-----|:------|:----------|
| Daily dumps | `/media/nas/HyperBrain_DBs_Backup/daily/` | 7 files |
| Weekly dumps | `/media/nas/HyperBrain_DBs_Backup/weekly/` | 4 files |
| Monthly dumps | `/media/nas/HyperBrain_DBs_Backup/monthly/` | 6 files |
| Off-site (age-encrypted) | `hb-offsite:HyperBrain/backups/` | managed by remote |

Backups run daily at **03:00 local time** via `hyperbrain-backup.timer`.
Weekly off-site upload runs every **Sunday**.

Format: PostgreSQL custom format (`pg_dump --format=custom`), restored with `pg_restore`.

---

## Setup

### 1. Install prerequisites on daniel-ubuntu

```bash
sudo apt install postgresql-client age
curl https://rclone.org/install.sh | sudo bash
```

### 2. Configure rclone remote

```bash
rclone config   # create remote named 'hb-offsite' (OCI Object Storage or Backblaze B2)
rclone lsd hb-offsite:   # verify access
```

### 3. Generate age key pair (if not already done)

```bash
age-keygen -o ~/.config/age/hyperbrain-backup.txt
# Output shows the public key — add it to /etc/hyperbrain/backup.env as BACKUP_AGE_RECIPIENT
# Keep the private key (~/.config/age/hyperbrain-backup.txt) safe; you need it to decrypt.
```

### 4. Install and enable the timer

```bash
cd /path/to/HyperBrain-Infra
sudo bash scripts/backup/install-backup.sh
# Edit /etc/hyperbrain/backup.env with real values
sudo systemctl start hyperbrain-backup.service   # test run
journalctl -u hyperbrain-backup.service -f
```

---

## Restore Procedure

### From a local NAS dump

```bash
# 1. Stop the application to avoid write conflicts.
docker compose stop hyperbrain-core

# 2. Pick a dump file.
ls -lh /media/nas/HyperBrain_DBs_Backup/daily/
# Example: hyperbrain_2026-07-04.dump

DUMP=/media/nas/HyperBrain_DBs_Backup/daily/hyperbrain_2026-07-04.dump
PG_HOST=localhost
PG_PORT=5432
PG_USER=hyperbrain
PG_DB=hyperbrain

# 3. Drop and recreate the target database (assumes a maintenance DB exists).
PGPASSWORD=<password> psql -h $PG_HOST -p $PG_PORT -U $PG_USER -d postgres \
    -c "DROP DATABASE IF EXISTS ${PG_DB};" \
    -c "CREATE DATABASE ${PG_DB} OWNER ${PG_USER};"

# 4. Restore.
PGPASSWORD=<password> pg_restore \
    -h $PG_HOST -p $PG_PORT -U $PG_USER \
    --dbname=$PG_DB \
    --no-owner --role=$PG_USER \
    --verbose \
    "$DUMP"

# 5. Verify row counts on key tables.
PGPASSWORD=<password> psql -h $PG_HOST -p $PG_PORT -U $PG_USER -d $PG_DB \
    -c "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 10;"

# 6. Restart the application.
docker compose start hyperbrain-core
curl http://localhost:8080/actuator/health
```

### From an off-site encrypted backup

```bash
# 1. Download the encrypted file.
rclone copy hb-offsite:HyperBrain/backups/hyperbrain_2026-07-04.dump.age /tmp/

# 2. Decrypt with your age private key.
age --decrypt \
    --identity ~/.config/age/hyperbrain-backup.txt \
    -o /tmp/hyperbrain_2026-07-04.dump \
    /tmp/hyperbrain_2026-07-04.dump.age

# 3. Follow steps 1–6 from the local restore procedure above,
#    using DUMP=/tmp/hyperbrain_2026-07-04.dump.
```

---

## Verify Backup Integrity

Run after every restore test or ad-hoc:

```bash
DUMP=/media/nas/HyperBrain_DBs_Backup/daily/hyperbrain_$(date +%Y-%m-%d).dump

# Check the dump is a valid custom-format archive (no data extraction).
pg_restore --list "$DUMP" | head -30

# Check file size is non-zero and reasonable.
du -h "$DUMP"
```

---

## Grafana Alert

A Grafana alert (`backup-stale.yml`) fires if no successful backup has been recorded in the last **26 hours**.
The alert depends on `node_exporter` textfile_collector. See deployment instructions in
`infrastructure/grafana/provisioning/alerting/backup-stale.yml`.

If the alert fires: `journalctl -u hyperbrain-backup.service -n 50 --no-pager`

---

## Rotate the off-site encryption key

```bash
# 1. Generate a new key pair.
age-keygen -o ~/.config/age/hyperbrain-backup-new.txt

# 2. Update BACKUP_AGE_RECIPIENT in /etc/hyperbrain/backup.env with the new public key.
# 3. Re-encrypt existing off-site files if needed (manual step, not scripted).
# 4. Delete the old private key only after confirming a new encrypted backup exists.
```
