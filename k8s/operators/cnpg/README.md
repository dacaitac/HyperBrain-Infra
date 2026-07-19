# CloudNativePG operator — vendored manifest

| Field | Value |
| :--- | :--- |
| Version | **1.29.2** (latest 1.2x patch at vendoring time, 2026-07-18) |
| File | `cnpg-1.29.2.yaml` |
| Source | `https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.29/releases/cnpg-1.29.2.yaml` |
| Installs into | namespace `cnpg-system` (created by the manifest) |

Applied **separately from and before** the `k8s/overlays/prod` overlay (the
`Cluster` CR in `k8s/base/db/` needs the CRDs):

```bash
kubectl apply --server-side -f k8s/operators/cnpg/cnpg-1.29.2.yaml
```

To re-vendor a new version: download the release manifest from the matching
`release-1.x` branch, commit it under a new filename, update this table and
apply. Operator upgrades restart the operator pod only; the PG instances keep
running (rolling restart happens on operand image changes, not operator ones).
