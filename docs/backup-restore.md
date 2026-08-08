# HyperBrain — Backup & Restore

## Overview (current, post-Infra#28)

Production runs on k3s + CloudNativePG (ADR-021). The **permanent** off-site backup mechanism is
the K8s CronJob `pg-dump-offsite` (`k8s/base/backup/pg-dump-offsite-cronjob.yaml`) — promoted from
*interim* to permanent by Infra#28 (2026-08-07): it dumps `hyperbrain-db-rw.hyperbrain.svc`
directly, so it is unaffected by which node currently holds the CNPG primary and does not depend on
`daniel-ubuntu` being present.

| What | Where | Retention |
|:-----|:------|:----------|
| Off-site (age-encrypted) daily dump | `hb-offsite:<bucket-name>/backups/` — bucket name is the Terraform output `bucket_name` (dedicated S3 bucket, see `terraform/backup-offsite/`); the rclone remote's bucket **is** the first path segment, so `BACKUP_OFFSITE_PATH` must include it (e.g. `hyperbrain-backup-offsite-<account-id>/backups`), not just `backups` | managed by the bucket's lifecycle rule (90 days on noncurrent versions) |

CNPG itself has **no managed base backup** (`firstRecoverabilityPoint`/`lastSuccessfulBackup` are
`None` as of the Infra#28 audit) — the *only* other redundancy today is the intra-cluster streaming
replica (lag 0). This CronJob's dump is therefore the sole logical off-site copy; see Infra#21 for
the tracked follow-up to add CNPG-native `barman`/object-store backup as a second layer.

Format: PostgreSQL custom format (`pg_dump --format=custom`), restored with `pg_restore`.

**Legacy NAS/systemd chain (`hyperbrain-backup.timer` on daniel-ubuntu):** the Infra#28 audit found
this **broken** — it still targets `localhost:5432`, which was the docker-compose Postgres
container retired when the DB moved into CNPG; it has been writing 0-byte `.dump` files daily and
failing silently (no alert notification policy existed either — see below). It is being retired,
not repointed — see `docs/runbook-daniel-ubuntu-join.md` §3. The setup/restore instructions below
for the NAS tier are kept only as historical reference until the unit is formally disabled.

---

## Setup — off-site remote (`hb-offsite`)

`hb-offsite` must be a **dedicated** rclone remote, not one of Daniel's personal remotes
(`unacional`/`i7_danielcc` exist in `~/.config/rclone/rclone.conf` on daniel-ubuntu and were the
root cause of Infra#28 — `BACKUP_RCLONE_REMOTE=hb-offsite` pointed at a stanza that was never
created; the base64'd `rclone.conf` embedded in `secrets.enc.env` only ever carried the two personal
remotes). Provisioning: `terraform/backup-offsite/` (S3 bucket + scoped IAM user, see that
module's README). The `rclone.conf` stanza that goes into `secrets.enc.env` must contain **only**
`[hb-offsite]` — never Daniel's personal remotes (Security condition, Infra#28 committee review).

```ini
[hb-offsite]
type = s3
provider = AWS
env_auth = false
access_key_id = <from: aws iam create-access-key --user-name hyperbrain-backup-offsite>
secret_access_key = <same>
region = us-east-1
no_check_bucket = true
```

`no_check_bucket = true` is required, not optional: the IAM policy deliberately grants only
`s3:ListBucket`/`PutObject`/`GetObject` (no `s3:CreateBucket` — least privilege, Infra#28 committee
condition), and rclone's default behavior probes/creates the bucket before the first upload. Without
this flag every upload fails with `AccessDenied: ... s3:CreateBucket`.

Regenerate `secrets.enc.env` and the `hyperbrain-secrets` Secret via the CD flow documented in
`k8s/README.md` — never `kubectl edit`/`kubectl create secret` by hand (breaks the "cluster
reconstructible from the repo" invariant).

### Generate the age key pair (if not already done)

`BACKUP_AGE_RECIPIENT` currently reuses the **same** age keypair as SOPS
(`~/.config/sops/age/keys.txt`, recipient `age1lpq…` in `.sops.yaml`) — convenient (one key to
manage) but couples backup-decryption capability to SOPS-decryption capability. Worth splitting into
a dedicated backup-only keypair post-MVP; not blocking for #28.

```bash
age-keygen -o ~/.config/age/hyperbrain-backup.txt
# Public key -> BACKUP_AGE_RECIPIENT in secrets.enc.env
```

---

## Force a manual run / verify

```bash
kubectl create job -n hyperbrain --from=cronjob/pg-dump-offsite pg-dump-offsite-manual-$(date +%s)
kubectl get jobs -n hyperbrain -l app=pg-dump-offsite -w    # wait for Succeeded
kubectl logs -n hyperbrain -l job-name=<job-name>
rclone --config <path> lsl hb-offsite:<bucket-name>/backups/   # confirm the .dump.age object landed
```

---

## Restore drill (do this, not just "Succeeded" — Infra#28 committee condition)

A green CronJob run is not a verified backup. Run this after every remote/credential change and
periodically thereafter:

```bash
# 1. Download (S3 directly — simpler than configuring rclone locally for a one-off)
#    and decrypt to a path with 600 perms, never a shared /tmp.
mkdir -m 700 -p ~/restore-drill && cd ~/restore-drill
aws s3 cp s3://<bucket-name>/backups/hyperbrain_<date>.dump.age . --profile hb-admin
age --decrypt --identity ~/.config/sops/age/keys.txt \
    -o hyperbrain_<date>.dump hyperbrain_<date>.dump.age
chmod 600 hyperbrain_<date>.dump
rm -f hyperbrain_<date>.dump.age   # the age key never leaves this machine either

# 2. Disposable, single-instance CNPG Cluster — never the production cluster,
#    no Service exposed via Tailscale, no NodePort (plain ClusterIP, default).
cat > drill-cluster.yaml <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: hyperbrain-restore-drill
  namespace: hyperbrain
  labels:
    purpose: infra28-restore-drill
spec:
  instances: 1
  imageName: ghcr.io/dacaitac/cnpg-pgvector:16
  enableSuperuserAccess: true
  bootstrap:
    initdb:
      database: hyperbrain
      owner: hyperbrain
  storage:
    storageClass: local-path
    size: 5Gi
EOF
kubectl apply -f drill-cluster.yaml
kubectl wait --for=condition=Ready cluster/hyperbrain-restore-drill -n hyperbrain --timeout=180s

# 3. Restore. The CNPG operand image has a read-only root filesystem (kubectl cp
#    to most paths fails with "Read-only file system") — /dev/shm is writable and
#    is the one place to stage the dump inside the pod. Running pg_restore/psql
#    via `kubectl exec` as the postgres user hits the local Unix socket, no
#    PGPASSWORD/port-forward needed.
POD=$(kubectl get pods -n hyperbrain -l cnpg.io/cluster=hyperbrain-restore-drill -o jsonpath='{.items[0].metadata.name}')
kubectl cp hyperbrain_<date>.dump "hyperbrain/${POD}:/dev/shm/hyperbrain_<date>.dump"
kubectl exec -n hyperbrain "$POD" -- \
    pg_restore -U postgres --dbname=hyperbrain --no-owner --verbose /dev/shm/hyperbrain_<date>.dump
# Expect "errors ignored on restore: N" for GRANT ... TO authenticated — this disposable
# cluster has no Supabase/GoTrue roles (no `authenticated`/`anon`); harmless, data restores fine.

# 4. Validate schema + row counts (pg_stat_user_tables' column is `relname`, not `tablename`).
kubectl exec -n hyperbrain "$POD" -- psql -U postgres -d hyperbrain -c \
    "SELECT schemaname, relname AS tablename, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 15;"

# 5. Clean up — every time, no exceptions:
shred -f -u ~/restore-drill/hyperbrain_<date>.dump   # or: rm -P on macOS
kubectl delete cluster hyperbrain-restore-drill -n hyperbrain
kubectl delete pvc -n hyperbrain -l cnpg.io/cluster=hyperbrain-restore-drill   # CNPG PVCs outlive the Cluster delete
rm -rf ~/restore-drill
```

The age **private** key is never copied onto the drill DB or any pod — decryption happens only on
the operator's machine, outside the cluster.

**Executed and verified 2026-08-08** (Infra#28): real production data restored into a from-empty
CNPG cluster and confirmed via row counts (`core_executable`: 402, `core_cycle`: 40,
`processed_message`: 15476, `sys_user`: 1, among others) — the off-site dump is a genuine,
self-contained, restorable backup, not just a green CronJob.

---

## Real recovery runbook (greenfield bootstrap — exercise at least once, Infra#28)

The restore drill above proves the dump is readable; it does not prove HyperBrain can come back from
**zero** (new cluster, no CNPG state at all). Walk this at least once and keep it current:

1. **Bootstrap CNPG greenfield.** Apply `k8s/base/db/cluster.yaml` against a cluster/namespace with
   no existing CNPG `Cluster` object of that name — the `initdb` bootstrap creates an empty
   `hyperbrain` database and the `hyperbrain-db-app`/`hyperbrain-db-superuser` Secrets.
2. **Run the migrations Job.** `k8s/base/db/migrate-job.yaml` (via `k8s/base/db/apply-migrations.sh`)
   applies all 17 `supabase/migrations/*.sql` in order — this recreates the schema the dump expects.
   Do **not** skip this step and rely on `pg_restore --create`: the migrations are the schema source
   of truth (`k8s/README.md`), and skipping them means the restored dump's schema and the Flyway
   mirror in `HyperBrain-core` (`V1__init.sql`) can drift silently.
3. **`pg_restore` the dump** into the now-migrated, empty database (same command as the drill above,
   step 2) — the schema already matches, so this is a data-only load in practice even though the
   dump is a full `--format=custom` archive.
4. **Verify** row counts (as in the drill) and that `hyperbrain-core` connects and passes
   `/actuator/health` against the recovered cluster.

**Status (Infra#28): the restore drill above was executed and verified 2026-08-08** — real data
restored from a from-empty CNPG cluster (see previous section). **This greenfield walkthrough
(migrations-first, as opposed to letting the dump's own `CREATE TABLE`s define the schema) remains
documented but not yet executed** — tracked as a follow-up under Infra#21, since the executed drill
already proves the dump is self-contained and restorable; the migrations-first path matters mainly
for the edge case of schema drift between the dump and migrations applied since. It is not
automated/scripted end-to-end in this repo — worth scripting under Infra#21 if RTO ever needs to be
tightened.

---

## Alerting

`infrastructure/monitoring-oci/grafana/provisioning/alerting/`:

- `backup-stale.yml` — legacy NAS-chain alert (`hyperbrain_backup_last_success_timestamp` via
  node_exporter textfile collector). Stays defined for history; the timer it watches is being
  retired (see `docs/runbook-daniel-ubuntu-join.md` §3) so this rule is expected to go permanently
  stale — do not chase it once the timer is disabled.
- `cluster-alerts.yml` → `hb-interim-backup-stale-001` — the live one: fires if
  `kube_cronjob_status_last_successful_time{cronjob="pg-dump-offsite"}` is more than 26h old (via
  kube-state-metrics, zero extra plumbing needed inside the CronJob).
- `contactpoints.yml` — contact point + notification policy for the "HyperBrain" folder. **Both
  alert rules above existed with no contact point wired for weeks; that's why 3 failed runs never
  notified anyone (Infra#28).** This file is a placeholder (webhook/email channel not yet chosen) —
  finishing it, choosing the real channel (iPhone push via Grafana + Prometheus), deploying it, and
  firing a real test alert is tracked as its own issue, **Infra#30** (this sprint), not blocking
  Infra#28's closure. Deploy once filled in:
  ```bash
  scp infrastructure/monitoring-oci/grafana/provisioning/alerting/*.yml \
      ubuntu@100.110.72.116:/opt/hyperbrain/monitoring/grafana/provisioning/alerting/
  ssh ubuntu@100.110.72.116 'cd /opt/hyperbrain/monitoring && docker compose restart grafana'
  ```
  `/opt/hyperbrain/monitoring` on the OCI host is a manual copy, not git-checked-out — provisioning
  changes must be scp'd (or rsynced) after every edit here.

If an alert fires: `kubectl get jobs -n hyperbrain -l app=pg-dump-offsite` / `kubectl logs -n
hyperbrain -l app=pg-dump-offsite`.

---

## Legacy: NAS-local restore (historical — being retired, see above)

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

## Legacy: verify NAS backup integrity

```bash
DUMP=/media/nas/HyperBrain_DBs_Backup/daily/hyperbrain_$(date +%Y-%m-%d).dump

# Check the dump is a valid custom-format archive (no data extraction).
pg_restore --list "$DUMP" | head -30

# Check file size is non-zero and reasonable.
du -h "$DUMP"
```

## Rotate the off-site encryption key

```bash
# 1. Generate a new key pair.
age-keygen -o ~/.config/age/hyperbrain-backup-new.txt

# 2. Update BACKUP_AGE_RECIPIENT in secrets.enc.env (K8s CronJob) and/or
#    /etc/hyperbrain/backup.env (legacy, while it still exists) with the new public key.
# 3. Re-encrypt existing off-site files if needed (manual step, not scripted).
# 4. Delete the old private key only after confirming a new encrypted backup exists.
```
