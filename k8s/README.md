# k8s/ — production manifests (ADR-021)

Kustomize tree for the k3s multi-node cluster. Live documentation:
`HyperBrain-docs/docs/02-architecture/infrastructure/deployment.md`.

## Apply order

```bash
# 1. CNPG operator (CRDs) — vendored, pinned
kubectl apply --server-side -f k8s/operators/cnpg/cnpg-1.29.2.yaml

# 2. Secrets (out-of-band: SOPS -> kubectl by the CD/hub, never in git)
#    See "hyperbrain-secrets contract" below.

# 3. Everything else
kubectl apply -k k8s/overlays/prod
```

## `hyperbrain-secrets` contract (namespace `hyperbrain`)

Created out-of-band (SOPS + `kubectl create secret generic`). Expected keys:

| Key | Consumer | Content |
| :--- | :--- | :--- |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | core | Runtime SQS IAM user (needs `ChangeMessageVisibility` — see 2026-07-10 incident) |
| `SQS_QUEUE_SYNC_EVENTS` | core | Full URL of `sync-events.fifo` |
| `SQS_QUEUE_APPLE_COMMANDS` | core | Full URL of `apple-commands.fifo` |
| `SQS_QUEUE_APPLE_COMMANDS_RESULTS` | core | Full URL of `apple-commands-results.fifo` |
| `SQS_QUEUE_USER_COMMANDS` | core | Full URL of `user-commands.fifo` |
| `GOTRUE_JWT_SECRET` | gotrue | Supabase JWT secret |
| `PGRST_JWT_SECRET` | postgrest | Same JWT secret value |
| `NOTION_TOKEN` | core | May be empty until the Notion re-link issue (sync is OFF) |
| `BACKUP_AGE_RECIPIENT` | backup CronJob | age public key |
| `BACKUP_RCLONE_REMOTE` | backup CronJob | rclone remote name (e.g. `hb-offsite`) |
| `BACKUP_OFFSITE_PATH` | backup CronJob | e.g. `HyperBrain/backups` |
| `rclone.conf` | backup CronJob | Full rclone config file (mounted, not env) |

DB credentials are **not** here: CNPG generates `hyperbrain-db-app`
(bootstrap owner) and `hyperbrain-db-superuser` (enableSuperuserAccess) and
the manifests reference those directly.

## Layout notes

- `base/db/migrations/` is **generated** by `scripts/k8s/sync-migrations.sh`
  from `supabase/migrations/` (kustomize load restrictions forbid generator
  files outside the root). Re-run + commit after adding a migration; CI checks
  parity with `--check`.
- `components/ladder-affinity/` is the **only** place with the D4 ladder
  weights for stateless workloads; the CNPG Cluster carries its own inverted
  weights (standby off-site) in `base/db/cluster.yaml`.
- `base/appsmith/` is prepared but excluded from the build until Sprint 3 #45.
- Descheduler runs in `kube-system`; do not add a global `namespace:` to the
  base kustomization.
- Rollback (D6): re-apply the previous manifest / previous `newTag` in
  `overlays/prod/kustomization.yaml`.
