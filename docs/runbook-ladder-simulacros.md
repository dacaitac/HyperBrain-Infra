# Runbook — Ladder simulations S1–S4 (ADR-021 F10' / D8)

Acceptance tests of the D4 ladder (weights: daniel-ubuntu=100 > mac-mini=60 >
oci=30; DB affinity inverted so the standby stays off-site in OCI). Each
simulation has explicit commands and **measurable pass criteria**. Run them in
order; S1/S2 are deliberate outages — schedule them, don't fear them.

Before any simulation, capture the baseline:

```bash
kubectl get nodes -o wide
kubectl get pods -n hyperbrain -o wide
kubectl cnpg status hyperbrain-db -n hyperbrain
date -u   # note T0
```

---

## S1 — daniel-ubuntu dies (the original incident, unplanned)

**Action:** power off daniel-ubuntu abruptly (no drain).

```bash
# Watch from a tailnet host:
kubectl get nodes -w                       # daniel-ubuntu -> NotReady
kubectl get pods -n hyperbrain -o wide -w  # stateless pods reschedule
kubectl cnpg status hyperbrain-db -n hyperbrain   # failover if primary was there
curl -sf http://hyperbrain-core:8080/actuator/health   # service continuity
```

**Pass criteria (all measurable):**

| # | Criterion | Target |
| :-- | :--- | :--- |
| S1.1 | Stateless pods (core/gotrue/postgrest/ksm) Running on mac-mini-vm (next rung) | ≤ 5 min after NotReady |
| S1.2 | If the primary was on daniel-ubuntu: CNPG promotes the standby | RTO ≤ 5 min, RPO ≤ 60 s |
| S1.3 | `/actuator/health` responds via tailnet | UP within 10 min |
| S1.4 | Grafana fires "k3s node NotReady >5m" | alert received |
| S1.5 | No CNPG pod evicted by the descheduler (triple barrier) | `kubectl get events -n hyperbrain` shows no eviction of hyperbrain-db-* |

## S2 — mac-mini-vm dies (T1 of the ADR)

**Action:** `limactl stop hyperbrain-k3s` on the Mac Mini (or kill the VM).

**Pass criteria:**

| # | Criterion | Target |
| :-- | :--- | :--- |
| S2.1 | All stateless workloads Running on hyperbrain-oci (survival rung: control plane + monitoring + PG + core together) | ≤ 5 min |
| S2.2 | DB: instances on remaining nodes healthy, primary reachable (`hyperbrain-db:5432`) | continuous |
| S2.3 | Core health UP via tailnet | ≤ 10 min |
| S2.4 | SentinelAPI keeps queueing to SQS (no message loss; backlog drains after) | DLQs empty after recovery |

## S3 — mac-mini-vm returns (T2: the descheduler climbs back)

**Action:** `limactl start hyperbrain-k3s` (or wait for the LaunchAgent);
node rejoins automatically (k3s agent is installed persistently in the VM).

```bash
kubectl get node mac-mini-vm -w            # -> Ready
# Descheduler CronJob runs every 15 min:
kubectl get jobs -n kube-system -l app=hyperbrain-descheduler --sort-by=.metadata.creationTimestamp
kubectl get pods -n hyperbrain -o wide     # pods back on the best rung
```

**Pass criteria:**

| # | Criterion | Target |
| :-- | :--- | :--- |
| S3.1 | Stateless pods return to mac-mini-vm (best available rung, daniel-ubuntu still down) **without manual action** | ≤ 30 min (2 descheduler cycles) |
| S3.2 | Evictions limited to `reschedulable=true` pods, ≤ 2 per node per cycle | events audit |
| S3.3 | No CNPG instance moved | `kubectl cnpg status` unchanged |
| S3.4 | Service stays up during the moves (rolling: evict -> reschedule) | health check never fails > 60 s |

## S4 — daniel-ubuntu returns (T3: full ladder + directed switchover)

**Action:** power on daniel-ubuntu; if it is a fresh install, run
[runbook-daniel-ubuntu-join.md](runbook-daniel-ubuntu-join.md) §1; then §2
(primary switchback 3→switchover→2).

**Pass criteria:**

| # | Criterion | Target |
| :-- | :--- | :--- |
| S4.1 | Node Ready with `ladder-tier=daniel-ubuntu` | ≤ 10 min from boot |
| S4.2 | Descheduler returns stateless workloads to daniel-ubuntu without manual action | ≤ 30 min |
| S4.3 | PG primary on daniel-ubuntu after **manual** `kubectl cnpg promote`; write pause during switchover | ≤ 30 s pause |
| S4.4 | Standby remains on hyperbrain-oci (off-site) after scaling back to 2 | `kubectl get pods -o wide` |
| S4.5 | End-to-end: iOS reminder -> SQS -> core -> PG round-trip works | manual smoke test |

---

**Closure:** S1–S4 green ⇒ D8 criterion met ⇒ issues **#35** and **#69** can
close (per ADR-021). Record results (dates, measured times) in the issues and
let `docs-scribe` update `deployment.md` with the verified topology.
