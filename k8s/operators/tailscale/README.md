# Tailscale Kubernetes Operator — vendored manifest

| Field | Value |
| :--- | :--- |
| Version | **v1.98.8** (latest stable at vendoring time, 2026-07-18) |
| File | `tailscale-operator-1.98.8.yaml` |
| Source | `https://raw.githubusercontent.com/tailscale/tailscale/v1.98.8/cmd/k8s-operator/deploy/manifests/operator.yaml` (official static manifest) |
| Local pin | `image:`/`PROXY_IMAGE` changed from `:stable` to `v1.98.8` (upstream ships the static manifest unpinned) |
| Installs into | namespace `tailscale` (created by the manifest) |

Regeneration (either path, then re-pin the two `:stable` references):

```bash
# a) static manifest (no helm needed — used here)
curl -fL -o tailscale-operator-<ver>.yaml \
  https://raw.githubusercontent.com/tailscale/tailscale/v<ver>/cmd/k8s-operator/deploy/manifests/operator.yaml
# b) helm template render
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm template tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale --version <ver> > tailscale-operator-<ver>.yaml
```

## Prerequisite: `operator-oauth` Secret (created by Daniel, out of band)

The operator authenticates with an OAuth client — official guide:
<https://tailscale.com/kb/1236/kubernetes-operator>.

1. **ACL (admin console → Access Controls):** define the tags the operator
   uses (`tag:k8s-operator` owns the proxies' `tag:k8s`):

   ```jsonc
   "tagOwners": {
     "tag:k8s-operator": [],
     "tag:k8s":          ["tag:k8s-operator"],
   }
   ```

2. **OAuth client (admin console → Settings → OAuth clients):** scopes
   **Devices Core (write)** and **Auth Keys (write)**, tag `tag:k8s-operator`.

3. **Secret:**

   ```bash
   kubectl create secret generic operator-oauth -n tailscale \
     --from-literal=client_id=<OAUTH_CLIENT_ID> \
     --from-literal=client_secret=<OAUTH_CLIENT_SECRET>
   ```

The operator crash-loops harmlessly until the Secret exists.

## How exposure works here (ADR-021 D2)

Services are exposed to the tailnet with the idiomatic annotations
`tailscale.com/expose: "true"` + `tailscale.com/hostname: <name>` — applied
**only in `k8s/overlays/prod`** (patches/), never in base. The operator spawns
one proxy pod (`tag:k8s`) per annotated Service; nothing listens on LAN or
public interfaces (RNF-09 preserved by construction).

| Service | Tailnet hostname |
| :--- | :--- |
| core | `hyperbrain-core` |
| postgrest | `hyperbrain-postgrest` |
| gotrue | `hyperbrain-gotrue` |
| CNPG rw (5432 + 9187 metrics) | `hyperbrain-db` |
| CNPG ro (9187 metrics) | `hyperbrain-db-ro` |
| kube-state-metrics | `hyperbrain-ksm` |
