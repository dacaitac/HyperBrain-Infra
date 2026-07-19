# Runbook — daniel-ubuntu joins / leaves the k3s cluster (ADR-021 F10')

Human-executed procedures. All `kubectl` from a tailnet host with the cluster
kubeconfig; the `cnpg` commands need the kubectl plugin
(`kubectl krew install cnpg` or the release binary matching operator 1.29.x).

## 1. Join (first time or after a rebuild)

```bash
# On daniel-ubuntu — prerequisites
tailscale ip -4                       # expect 100.83.47.113
# Token, on hyperbrain-oci:
#   sudo cat /var/lib/rancher/k3s/server/node-token

# From a checkout of HyperBrain-Infra on daniel-ubuntu:
sudo env K3S_TOKEN=<token> scripts/k8s/join-daniel-ubuntu.sh
```

Verification:

```bash
kubectl get node daniel-ubuntu --show-labels   # Ready + hyperbrain.dev/ladder-tier=daniel-ubuntu
kubectl get pods -n hyperbrain -o wide         # within ≤15 min the descheduler
                                               # moves stateless pods to the top rung
```

## 2. Return the PG primary to daniel-ubuntu (3 → switchover → 2)

The ladder switchback for CNPG is a **directed switchover, never an eviction**
(D4). Safe sequence — never drops below 2 healthy instances:

```bash
# 2.1 Scale 2 -> 3: the operator builds a new replica; node affinity
#     (daniel-ubuntu weight 100) places it on the returning host.
kubectl patch cluster hyperbrain-db -n hyperbrain \
  --type merge -p '{"spec":{"instances":3}}'
kubectl cnpg status hyperbrain-db -n hyperbrain     # wait: 3 instances, lag ≈ 0

# 2.2 Identify the instance running on daniel-ubuntu:
kubectl get pods -n hyperbrain -l cnpg.io/cluster=hyperbrain-db -o wide

# 2.3 Directed switchover (seconds of write pause — Daniel picks the moment):
kubectl cnpg promote hyperbrain-db <instance-on-daniel-ubuntu> -n hyperbrain
kubectl cnpg status hyperbrain-db -n hyperbrain     # primary now on daniel-ubuntu

# 2.4 Scale 3 -> 2 keeping the OCI standby (off-site replica is the whole
#     point). Scale down, then VERIFY which standby remained:
kubectl patch cluster hyperbrain-db -n hyperbrain \
  --type merge -p '{"spec":{"instances":2}}'
kubectl get pods -n hyperbrain -l cnpg.io/cluster=hyperbrain-db -o wide
# If the surviving standby is NOT on hyperbrain-oci: go back to instances=3,
# remove the wrong standby explicitly with
#   kubectl cnpg destroy hyperbrain-db <serial-of-mac-mini-standby> -n hyperbrain
# and scale to 2 again.
```

## 3. Re-enable the NAS backup chain, retire the interim CronJob

```bash
# On daniel-ubuntu — point the systemd chain at the cluster primary via tailnet:
sudo sed -i 's/^BACKUP_PG_HOST=.*/BACKUP_PG_HOST=hyperbrain-db/' /etc/hyperbrain/backup.env
# BACKUP_PG_USER/PASSWORD: superuser credentials from the cluster:
#   kubectl get secret hyperbrain-db-superuser -n hyperbrain \
#     -o jsonpath='{.data.password}' | base64 -d
sudo systemctl start hyperbrain-backup.service     # manual run
journalctl -u hyperbrain-backup.service -n 20      # verify dump OK

# Then retire the interim (ADR-021 D3 says the interim is removed, in the repo,
# not ad-hoc): delete k8s/base/backup/pg-dump-offsite-cronjob.yaml + its entry
# in k8s/base/kustomization.yaml + the hb-interim-backup-stale-001 alert, and
# let the CD apply it. The legacy backup-stale.yml alert (NAS chain) takes over.
```

## 4. Planned exit (maintenance on daniel-ubuntu)

```bash
# 4.1 Move the primary away FIRST (directed switchover to the OCI standby):
kubectl cnpg promote hyperbrain-db <instance-on-hyperbrain-oci> -n hyperbrain
# 4.2 Drain (stateless pods fall down the ladder; CNPG protected by its PDB —
#     its standby on this node is gone while the host is away, that is T3-in-reverse):
kubectl drain daniel-ubuntu --ignore-daemonsets --delete-emptydir-data --timeout=5m
# 4.3 Power off / maintain. On return:
kubectl uncordon daniel-ubuntu
# then section 2 to bring the primary back.
```

## 5. Unplanned exit (host dies)

No action required to survive: this is exactly simulation **S1** in
[runbook-ladder-simulacros.md](runbook-ladder-simulacros.md) — tolerations
(60s) move stateless pods down the ladder, CNPG promotes the surviving
standby. On return, run sections 1–3 of this runbook.
