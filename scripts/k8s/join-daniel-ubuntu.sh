#!/usr/bin/env bash
# =============================================================================
# join-daniel-ubuntu.sh — rejoin daniel-ubuntu to the cluster (ADR-021 F10'/T3)
#
# Human-executed runbook step, ON daniel-ubuntu, when the host returns:
#
#   1. Verify tailscale is up:      tailscale ip -4   (expected 100.83.47.113)
#   2. Get the token on hyperbrain-oci:
#        sudo cat /var/lib/rancher/k3s/server/node-token
#   3. Run (from a checkout of HyperBrain-Infra):
#        sudo env K3S_TOKEN=<token> scripts/k8s/join-daniel-ubuntu.sh
#
# After the node is Ready:
#   - the descheduler returns stateless workloads to the top rung (T2/T3)
#   - the PG primary returns via a DIRECTED switchover (manual, D4):
#        kubectl cnpg promote hyperbrain-db <instance-on-daniel-ubuntu> -n hyperbrain
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOIN="${SCRIPT_DIR}/../../infrastructure/mac-mini-vm/join-node.sh"

[[ -f "${JOIN}" ]] || { echo "ERROR: join-node.sh not found at ${JOIN}" >&2; exit 1; }

exec bash "${JOIN}" daniel-ubuntu daniel-ubuntu
