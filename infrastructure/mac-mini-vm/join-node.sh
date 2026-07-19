#!/usr/bin/env bash
# =============================================================================
# join-node.sh — join a Linux node to the HyperBrain k3s cluster (ADR-021 D1/D2)
#
# Generic: reusable for the Lima VM (mac-mini-vm) and for daniel-ubuntu.
# Run INSIDE the node, as root. The tailnet is the cluster underlay (D2):
# tailscale must already be up on the node before joining.
#
# Usage:
#   sudo env K3S_TOKEN=<server-token> ./join-node.sh <NODE_NAME> <LADDER_TIER>
#
#   NODE_NAME    e.g. mac-mini-vm | daniel-ubuntu     (also via env NODE_NAME)
#   LADDER_TIER  e.g. mac-mini | daniel-ubuntu | oci  (also via env LADDER_TIER)
#   K3S_TOKEN    env only (never argv — visible in `ps`). From the server:
#                sudo cat /var/lib/rancher/k3s/server/node-token  (on hyperbrain-oci)
#
# Optional env:
#   K3S_URL      default https://100.110.72.116:6443 (hyperbrain-oci, tailnet)
#   K3S_VERSION  default v1.36.2+k3s1 — MUST match the server version
# =============================================================================
set -euo pipefail

NODE_NAME="${1:-${NODE_NAME:-}}"
LADDER_TIER="${2:-${LADDER_TIER:-}}"
K3S_URL="${K3S_URL:-https://100.110.72.116:6443}"
K3S_VERSION="${K3S_VERSION:-v1.36.2+k3s1}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "must run as root (sudo)"
[[ -n "${NODE_NAME}" ]] || die "NODE_NAME missing (arg 1 or env)"
[[ -n "${LADDER_TIER}" ]] || die "LADDER_TIER missing (arg 2 or env)"
[[ -n "${K3S_TOKEN:-}" ]] || die "K3S_TOKEN env var missing (k3s server node-token)"
command -v tailscale >/dev/null 2>&1 || die "tailscale not installed"

# Node IP = the node's own tailscale IPv4 (flannel runs over tailscale0, D2)
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
[[ -n "${TS_IP}" ]] || die "no tailscale IPv4 — run 'tailscale up' first (interactive)"

echo "Joining k3s cluster:"
echo "  server:      ${K3S_URL}"
echo "  node-name:   ${NODE_NAME}"
echo "  node-ip:     ${TS_IP} (tailscale0)"
echo "  ladder-tier: ${LADDER_TIER}"
echo "  version:     ${K3S_VERSION}"

curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  K3S_URL="${K3S_URL}" \
  K3S_TOKEN="${K3S_TOKEN}" \
  sh -s - agent \
    --node-name "${NODE_NAME}" \
    --node-ip "${TS_IP}" \
    --flannel-iface=tailscale0 \
    --node-label "hyperbrain.dev/ladder-tier=${LADDER_TIER}"

echo "k3s agent installed. Verify from a kubectl host:"
echo "  kubectl get node ${NODE_NAME} --show-labels"
