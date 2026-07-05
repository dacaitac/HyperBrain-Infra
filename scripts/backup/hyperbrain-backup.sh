#!/usr/bin/env bash
# Daily PostgreSQL backup for HyperBrain.
# Driven by hyperbrain-backup.timer at 03:00.
# On Sundays: uploads an age-encrypted copy off-site via rclone.
#
# Config is read from /etc/hyperbrain/backup.env (EnvironmentFile in the service unit).
# Required env vars: BACKUP_PG_USER, BACKUP_PG_PASSWORD, BACKUP_PG_DB,
#                    BACKUP_AGE_RECIPIENT (on Sundays), BACKUP_RCLONE_REMOTE (on Sundays).

set -euo pipefail

# ── configuration ────────────────────────────────────────────────────────────
NAS_DIR="${BACKUP_NAS_DIR:-/media/nas/HyperBrain_DBs_Backup}"
PG_HOST="${BACKUP_PG_HOST:-localhost}"
PG_PORT="${BACKUP_PG_PORT:-5432}"
PG_USER="${BACKUP_PG_USER}"
PG_PASSWORD="${BACKUP_PG_PASSWORD}"
PG_DB="${BACKUP_PG_DB}"
AGE_RECIPIENT="${BACKUP_AGE_RECIPIENT:-}"
RCLONE_REMOTE="${BACKUP_RCLONE_REMOTE:-hb-offsite}"
OFFSITE_PATH="${BACKUP_OFFSITE_PATH:-HyperBrain/backups}"
TEXTFILE_DIR="${BACKUP_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"

RETAIN_DAILY=7
RETAIN_WEEKLY=4
RETAIN_MONTHLY=6

# ── helpers ──────────────────────────────────────────────────────────────────
log() { echo "[$(date -Iseconds)] [hyperbrain-backup] $*"; }
die() { log "ERROR: $*" >&2; exit 1; }

today=$(date +%Y-%m-%d)
dow=$(date +%u)   # 1=Mon … 7=Sun
dom=$(date +%-d)  # day of month (no leading zero)

mkdir -p "${NAS_DIR}/daily" "${NAS_DIR}/weekly" "${NAS_DIR}/monthly"

# ── dump ─────────────────────────────────────────────────────────────────────
log "Starting pg_dump: ${PG_DB} @ ${PG_HOST}:${PG_PORT}"
DUMP_FILE="${NAS_DIR}/daily/hyperbrain_${today}.dump"
PGPASSWORD="${PG_PASSWORD}" pg_dump \
    -h "${PG_HOST}" -p "${PG_PORT}" -U "${PG_USER}" \
    --format=custom --compress=9 \
    --file="${DUMP_FILE}" \
    "${PG_DB}"
log "Dump written: ${DUMP_FILE} ($(du -h "${DUMP_FILE}" | cut -f1))"

# ── weekly copy (Sunday) ─────────────────────────────────────────────────────
if [[ "${dow}" == "7" ]]; then
    week=$(date +%G-W%V)   # ISO week: 2026-W27
    WEEKLY_FILE="${NAS_DIR}/weekly/hyperbrain_${week}.dump"
    cp "${DUMP_FILE}" "${WEEKLY_FILE}"
    log "Weekly copy: ${WEEKLY_FILE}"
fi

# ── monthly copy (1st of month) ──────────────────────────────────────────────
if [[ "${dom}" == "1" ]]; then
    month=$(date +%Y-%m)
    MONTHLY_FILE="${NAS_DIR}/monthly/hyperbrain_${month}.dump"
    cp "${DUMP_FILE}" "${MONTHLY_FILE}"
    log "Monthly copy: ${MONTHLY_FILE}"
fi

# ── retention ────────────────────────────────────────────────────────────────
log "Pruning: daily=${RETAIN_DAILY} weekly=${RETAIN_WEEKLY} monthly=${RETAIN_MONTHLY}"
# sort by filename (chronological because of YYYY-* format), delete oldest first
find "${NAS_DIR}/daily"   -maxdepth 1 -name "*.dump" | sort | head -n -"${RETAIN_DAILY}"   | xargs -r rm -v
find "${NAS_DIR}/weekly"  -maxdepth 1 -name "*.dump" | sort | head -n -"${RETAIN_WEEKLY}"  | xargs -r rm -v
find "${NAS_DIR}/monthly" -maxdepth 1 -name "*.dump" | sort | head -n -"${RETAIN_MONTHLY}" | xargs -r rm -v

# ── off-site (Sunday only) ───────────────────────────────────────────────────
if [[ "${dow}" == "7" ]]; then
    [[ -z "${AGE_RECIPIENT}" ]] && die "BACKUP_AGE_RECIPIENT not set — cannot encrypt off-site copy"
    which age   > /dev/null 2>&1 || die "'age' binary not found (install: apt install age)"
    which rclone > /dev/null 2>&1 || die "'rclone' binary not found (https://rclone.org/install/)"

    ENCRYPTED="/tmp/hyperbrain_${today}.dump.age"
    log "Encrypting ${WEEKLY_FILE:-${DUMP_FILE}} for off-site"
    age -r "${AGE_RECIPIENT}" -o "${ENCRYPTED}" "${WEEKLY_FILE:-${DUMP_FILE}}"
    log "Uploading to ${RCLONE_REMOTE}:${OFFSITE_PATH}/"
    rclone copy "${ENCRYPTED}" "${RCLONE_REMOTE}:${OFFSITE_PATH}/"
    rm -f "${ENCRYPTED}"
    log "Off-site upload complete"
fi

# ── prometheus sentinel ───────────────────────────────────────────────────────
# Written to node_exporter textfile_collector so Grafana can alert on stale backups.
if [[ -d "${TEXTFILE_DIR}" ]]; then
    cat > "${TEXTFILE_DIR}/hyperbrain_backup.prom" <<PROM
# HELP hyperbrain_backup_last_success_timestamp Unix timestamp of the last successful backup
# TYPE hyperbrain_backup_last_success_timestamp gauge
hyperbrain_backup_last_success_timestamp $(date +%s)
PROM
    log "Prometheus metric written to ${TEXTFILE_DIR}/hyperbrain_backup.prom"
fi

log "Backup complete"
