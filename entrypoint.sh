#!/bin/bash
set -euo pipefail

SCHEDULE="${BACKUP_CRON_SCHEDULE:-0 2 * * *}"
CRON_DIR=/tmp/crontabs
CRON_USER=$(id -un)
mkdir -p "$CRON_DIR"
echo "${SCHEDULE} /backup.sh >> /proc/1/fd/1 2>&1" > "${CRON_DIR}/${CRON_USER}"
chmod 600 "${CRON_DIR}/${CRON_USER}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  Cron schedule set to: ${SCHEDULE} (user: ${CRON_USER})"

# Run sanity checks only when starting the cron daemon, not for one-shot
# invocations like 'bash /backup.sh' used in tests and manual runs.
if [[ "${1:-}" == "crond" ]]; then
  /sanity_check.sh
fi

exec "$@"
