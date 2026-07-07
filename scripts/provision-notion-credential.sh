#!/usr/bin/env bash
# Upserts the Notion SYNC_CREDENTIAL row for the MVP system user (HU-10, CA-12).
#
# Reads NOTION_TOKEN (and PG connection vars) from .env so the secret never
# lands in git or in shell history. Idempotent: re-running replaces the token.
#
# Usage: ./scripts/provision-notion-credential.sh [path-to-env-file]
set -euo pipefail

ENV_FILE="${1:-$(dirname "$0")/../.env}"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: env file not found: $ENV_FILE" >&2
    exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

if [[ -z "${NOTION_TOKEN:-}" ]]; then
    echo "ERROR: NOTION_TOKEN is empty in $ENV_FILE — provision it first (see .env.example)" >&2
    exit 1
fi

# Single-user MVP: same fixture id used by the core (SYNC_DEFAULT_USER_ID) and tests.
SYSTEM_USER_ID="${SYNC_DEFAULT_USER_ID:-00000000-0000-0000-0000-000000000001}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"

PGPASSWORD="${POSTGRES_PASSWORD}" psql \
    -h "$PGHOST" -p "$PGPORT" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -v ON_ERROR_STOP=1 \
    -v user_id="$SYSTEM_USER_ID" \
    -v token="$NOTION_TOKEN" <<'SQL'
INSERT INTO sync_credential (user_id, provider, access_token)
VALUES (:'user_id', 'NOTION', :'token')
ON CONFLICT (user_id, provider)
DO UPDATE SET access_token = EXCLUDED.access_token;
SQL

echo "SYNC_CREDENTIAL (provider=NOTION) upserted for user $SYSTEM_USER_ID"
