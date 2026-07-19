# k8s/ — production manifests (ADR-021)

Kustomize tree for the k3s multi-node cluster. Live documentation:
`HyperBrain-docs/docs/02-architecture/infrastructure/deployment.md`.

## Apply order

```bash
# 1. Operators (CRDs) — vendored, pinned
kubectl apply --server-side -f k8s/operators/cnpg/cnpg-1.29.2.yaml
kubectl apply --server-side -f k8s/operators/tailscale/tailscale-operator-1.98.8.yaml

# 2. Secrets (out-of-band, never in git):
#    - hyperbrain-secrets  (SOPS -> kubectl; the CD does this from secrets.enc.env)
#    - operator-oauth      (namespace tailscale — see k8s/operators/tailscale/README.md)

# 3. Everything else
kubectl apply -k k8s/overlays/prod
```

The CD (`.github/workflows/deploy.yml`) performs 1–3 idempotently on every
push to `main`, from a GitHub-hosted runner joined ephemerally to the tailnet.

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

### Regenerating `secrets.enc.env` (Daniel, out of band)

The CD decrypts `secrets.enc.env` (repo root, SOPS+age) into the
`hyperbrain-secrets` Secret. It does not exist yet — the CD fails with a clear
preflight error until Daniel creates it:

```bash
# 1. Build a plaintext .env with ALL the env-style keys of the table above,
#    plus the rclone config as base64 (the CD turns it into the rclone.conf file key):
#      RCLONE_CONF_B64=$(base64 -w0 ~/.config/rclone/rclone.conf)
# 2. Encrypt (age private key stays in ~/.config/sops/age/keys.txt):
sops --encrypt --age <AGE_PUBLIC_KEY> .env > secrets.enc.env
# 3. Commit secrets.enc.env (encrypted file is safe in git); delete the plaintext.
```

### CD secrets (GitHub → environment `production`)

| Secret | Content |
| :--- | :--- |
| `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` | Tailscale OAuth client for CI (scopes Devices Core + Auth Keys write, tag `tag:ci`; add `"tag:ci": []` to `tagOwners` in the ACL) |
| `KUBECONFIG_B64` | `base64 -w0 kubeconfig` against `https://100.110.72.116:6443` (tailnet) |
| `SOPS_AGE_KEY` | age **private** key matching `secrets.enc.env` |

## Monitoring hookup (F8', Prometheus on hyperbrain-oci — outside the cluster)

- Scrape targets and tailnet hostnames: see
  `infrastructure/monitoring-oci/prometheus/prometheus.yml` and
  `k8s/operators/tailscale/README.md`.
- Kubelet scraping needs the `prometheus-scraper` token extracted once:

  ```bash
  kubectl -n hyperbrain get secret prometheus-scraper-token \
    -o jsonpath='{.data.token}' | base64 -d \
    > infrastructure/monitoring-oci/prometheus/k8s-scraper.token   # gitignored
  # copy to the OCI VM next to prometheus.yml and restart the prometheus container
  ```

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
