#!/usr/bin/env bash
# Installs the HyperBrain backup systemd units on daniel-ubuntu.
# Run once as root (or with sudo) from the repo root:
#   sudo bash scripts/backup/install-backup.sh
#
# Prerequisites on the host:
#   - pg_dump (postgresql-client)
#   - age  (apt install age)
#   - rclone configured with an 'hb-offsite' remote (https://rclone.org/install/)
#   - node_exporter with --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
#     (optional; enables the Grafana stale-backup alert)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DEST="/opt/hyperbrain/scripts"
UNIT_DEST="/etc/systemd/system"
ENV_FILE="/etc/hyperbrain/backup.env"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"

# ── install backup script ─────────────────────────────────────────────────────
install -d "${SCRIPT_DEST}"
install -m 0750 "${REPO_ROOT}/scripts/backup/hyperbrain-backup.sh" "${SCRIPT_DEST}/hyperbrain-backup.sh"
echo "Installed: ${SCRIPT_DEST}/hyperbrain-backup.sh"

# ── install systemd units ────────────────────────────────────────────────────
install -m 0644 "${REPO_ROOT}/infrastructure/systemd/hyperbrain-backup.service" "${UNIT_DEST}/"
install -m 0644 "${REPO_ROOT}/infrastructure/systemd/hyperbrain-backup.timer"   "${UNIT_DEST}/"
echo "Installed systemd units"

# ── environment file ──────────────────────────────────────────────────────────
install -d /etc/hyperbrain
if [[ ! -f "${ENV_FILE}" ]]; then
    cat > "${ENV_FILE}" <<'EOF'
# HyperBrain backup configuration — fill in real values, do NOT commit this file.
BACKUP_PG_HOST=localhost
BACKUP_PG_PORT=5432
BACKUP_PG_USER=hyperbrain
BACKUP_PG_PASSWORD=CHANGE_ME
BACKUP_PG_DB=hyperbrain
BACKUP_NAS_DIR=/media/nas/HyperBrain_DBs_Backup
BACKUP_AGE_RECIPIENT=age1...                # age public key for off-site encryption
BACKUP_RCLONE_REMOTE=hb-offsite            # rclone remote name
BACKUP_OFFSITE_PATH=HyperBrain/backups
BACKUP_TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
EOF
    chmod 0600 "${ENV_FILE}"
    echo "Created ${ENV_FILE} — fill in real values before enabling the timer."
else
    echo "Skipping ${ENV_FILE} (already exists)"
fi

# ── node_exporter textfile dir ────────────────────────────────────────────────
if [[ -d "${TEXTFILE_DIR}" ]]; then
    echo "node_exporter textfile dir exists: ${TEXTFILE_DIR}"
else
    echo "WARNING: ${TEXTFILE_DIR} not found."
    echo "  If node_exporter is installed, create the dir and add --collector.textfile.directory to its ExecStart."
    echo "  The Grafana stale-backup alert requires this."
fi

# ── reload and enable timer ───────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable --now hyperbrain-backup.timer
systemctl status hyperbrain-backup.timer --no-pager

echo ""
echo "Done. Next scheduled run:"
systemctl list-timers hyperbrain-backup.timer --no-pager
