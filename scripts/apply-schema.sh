#!/usr/bin/env bash
# Apply DDL v1 migrations + seeds to the Compose PostgreSQL (S0-02).
#
# CLI-less equivalent of `supabase db reset` for the local Compose stack:
# runs every file in supabase/migrations/ in lexicographic order, then seed.sql.
# Expects a schema-less database (like `db reset`, which drops first): the domain
# migrations use bare CREATE TABLE and are NOT re-runnable over a populated schema.
# The bootstrap migration and seed.sql ARE idempotent. Fails fast on any error.
#
# Usage: scripts/apply-schema.sh [--seed]   (--seed also applies supabase/seed.sql)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${PG_CONTAINER:-hyperbrain-postgres}"
MIGRATIONS_DIR="${REPO_ROOT}/supabase/migrations"
SEED_FILE="${REPO_ROOT}/supabase/seed.sql"

# Load DB credentials from .env
set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/.env"
set +a
DB_USER="${POSTGRES_USER}"
DB_NAME="${POSTGRES_DB}"

psql_exec() { docker exec -i "${CONTAINER}" psql -v ON_ERROR_STOP=1 -U "${DB_USER}" -d "${DB_NAME}" "$@"; }

echo "==> Applying migrations to ${CONTAINER} (${DB_NAME})"
for file in "${MIGRATIONS_DIR}"/*.sql; do
    echo "    - $(basename "${file}")"
    psql_exec -q < "${file}"
done

if [[ "${1:-}" == "--seed" ]]; then
    echo "==> Applying seeds (seed.sql)"
    psql_exec -q < "${SEED_FILE}"
fi

echo "==> Done."
