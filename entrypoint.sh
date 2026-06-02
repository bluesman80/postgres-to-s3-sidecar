#!/bin/bash
set -euo pipefail

SCHEDULE="${BACKUP_CRON_SCHEDULE:-0 2 * * *}"
echo "${SCHEDULE} /backup.sh >> /var/log/backup.log 2>&1" > /etc/crontabs/root
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  Cron schedule set to: ${SCHEDULE}"

exec "$@"
