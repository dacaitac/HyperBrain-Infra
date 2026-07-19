# =============================================================================
# CNPG operand image with pgvector (ADR-021 D3/F3')
#
# Replaces pgvector/pgvector:pg16 (Compose era): CloudNativePG requires its own
# operand image layout; we add the pgvector extension on top (ADR-003).
# Published multi-arch (amd64+arm64) as ghcr.io/dacaitac/cnpg-pgvector:16 by
# .github/workflows/images.yml — the cluster is heterogeneous by design (D5).
#
# Base pinned to the newest PG 16 minor available on GHCR at authoring time
# (2026-07-18). Bump deliberately; keep the same PG major as production.
# =============================================================================
FROM ghcr.io/cloudnative-pg/postgresql:16.14

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends postgresql-16-pgvector && \
    rm -rf /var/lib/apt/lists/*

# CNPG operand images must run as UID 26 (postgres)
USER 26
