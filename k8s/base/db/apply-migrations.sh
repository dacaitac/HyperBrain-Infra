#!/bin/bash
# =============================================================================
# apply-migrations.sh — runner for the db-migrate Job (ADR-021 D3/F4')
#
# Applies supabase/migrations/*.sql (mounted at /migrations from the
# hyperbrain-db-migrations ConfigMap) in lexicographic order against the CNPG
# rw Service, tracking applied files in infra.schema_migrations. Idempotent:
# already-applied migrations are skipped; each migration + its ledger row
# commit in a single transaction.
#
# Env (wired by migrate-job.yaml):
#   PGHOST / PGPORT / PGDATABASE
#   SUPERUSER_USERNAME / SUPERUSER_PASSWORD  (Secret hyperbrain-db-superuser)
#   APP_USERNAME / APP_PASSWORD              (Secret hyperbrain-db-app)
# =============================================================================
set -euo pipefail

MIGRATIONS_DIR="${MIGRATIONS_DIR:-/migrations}"

echo "== db-migrate: bootstrap (as ${SUPERUSER_USERNAME}) =="
# Compose parity: under Compose, POSTGRES_USER=hyperbrain WAS the cluster
# superuser, and every migration ran as it (object ownership + extension
# creation depend on that). Re-granting SUPERUSER keeps the 17 migrations
# byte-identical and the resulting DB identical to the pre-incident one.
# Hardening (least-privilege app role) is tracked as a post-migration issue.
PGUSER="${SUPERUSER_USERNAME}" PGPASSWORD="${SUPERUSER_PASSWORD}" \
  psql -v ON_ERROR_STOP=1 --no-psqlrc <<'SQL'
ALTER ROLE hyperbrain WITH SUPERUSER;
CREATE SCHEMA IF NOT EXISTS infra;
CREATE TABLE IF NOT EXISTS infra.schema_migrations (
  filename   text        PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
SQL

export PGUSER="${APP_USERNAME}"
export PGPASSWORD="${APP_PASSWORD}"

applied=0
skipped=0
while IFS= read -r file; do
  name="$(basename "${file}")"
  already="$(psql --no-psqlrc -tAc \
    "SELECT 1 FROM infra.schema_migrations WHERE filename = '${name}'")"
  if [[ "${already}" == "1" ]]; then
    echo "-- skip    ${name} (already applied)"
    skipped=$((skipped + 1))
    continue
  fi
  echo "== apply   ${name}"
  # -f + trailing -c run inside ONE transaction (--single-transaction):
  # the ledger row commits atomically with the migration itself.
  psql -v ON_ERROR_STOP=1 --no-psqlrc --single-transaction \
    -f "${file}" \
    -c "INSERT INTO infra.schema_migrations (filename) VALUES ('${name}')"
  applied=$((applied + 1))
done < <(find "${MIGRATIONS_DIR}" -maxdepth 1 -name '*.sql' | sort)

echo "== db-migrate: done (applied=${applied} skipped=${skipped}) =="
