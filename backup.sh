#!/bin/bash

set -euo pipefail

log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }

required_vars=(
  POSTGRES_HOST
  POSTGRES_USER
  POSTGRES_PASSWORD
  S3_BUCKET
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_DEFAULT_REGION
)

for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    log_error "Missing required environment variable: ${var_name}"
    exit 1
  fi
done
# Validate mutually exclusive backup mode
if [[ "${POSTGRES_BACKUP_ALL:-}" == "true" && -n "${POSTGRES_DB:-}" ]]; then
  log_error "POSTGRES_DB and POSTGRES_BACKUP_ALL=true are mutually exclusive. Set exactly one."
  exit 1
fi
if [[ "${POSTGRES_BACKUP_ALL:-}" != "true" && -z "${POSTGRES_DB:-}" ]]; then
  log_error "Neither POSTGRES_DB nor POSTGRES_BACKUP_ALL=true is set. Exactly one must be provided."
  exit 1
fi

POSTGRES_PORT=${POSTGRES_PORT:-5432}
S3_PREFIX=${S3_PREFIX:-backups}

export PGPASSWORD="$POSTGRES_PASSWORD"

BACKUP_TMPDIR=$(mktemp -d)
trap 'rm -rf "$BACKUP_TMPDIR"' EXIT

if [[ -x /hooks/pre-backup.sh ]]; then
  log_info "Running pre-backup hook: /hooks/pre-backup.sh"
  /hooks/pre-backup.sh
fi

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

if [[ "${POSTGRES_BACKUP_ALL:-}" == "true" ]]; then
  FILENAME="all_${TIMESTAMP}.sql.gz"
  S3_KEY="${S3_PREFIX}/${FILENAME}"
  log_info "Creating cluster-wide backup"
  pg_dumpall -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" | gzip > "$BACKUP_TMPDIR/$FILENAME"
elif [[ -n "${POSTGRES_DB:-}" ]]; then
  FILENAME="${POSTGRES_DB}_${TIMESTAMP}.dump.gz"
  S3_KEY="${S3_PREFIX}/${FILENAME}"
  read -r -a EXTRA_OPTS <<< "${POSTGRES_EXTRA_OPTS:-}"
  log_info "Creating database backup for ${POSTGRES_DB}"
  pg_dump -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -F c "${EXTRA_OPTS[@]}" "$POSTGRES_DB" | gzip > "$BACKUP_TMPDIR/$FILENAME"
else
  log_error "Neither POSTGRES_DB nor POSTGRES_BACKUP_ALL=true is set. Exiting."
  exit 1
fi

ENDPOINT_ARGS=()
if [[ -n "${AWS_ENDPOINT_URL:-}" ]]; then
  ENDPOINT_ARGS=("--endpoint-url" "$AWS_ENDPOINT_URL")
fi

aws s3 cp "$BACKUP_TMPDIR/$FILENAME" "s3://${S3_BUCKET}/${S3_KEY}" "${ENDPOINT_ARGS[@]}"
log_info "Backup uploaded to s3://${S3_BUCKET}/${S3_KEY}"

if [[ -x /hooks/post-backup.sh ]]; then
  log_info "Running post-backup hook: /hooks/post-backup.sh"
  /hooks/post-backup.sh
fi

log_info "Backup complete"
