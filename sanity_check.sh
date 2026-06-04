#!/bin/bash
# sanity_check.sh
# Runs connectivity and configuration checks at container startup,
# before the first cron job fires. Called by entrypoint.sh.

set -euo pipefail

log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }

pass() { log_info  "[PASS] $*"; }
fail() { log_error "[FAIL] $*"; exit 1; }
warn() { log_warn  "$*"; }

# ── Opt-out ───────────────────────────────────────────────────────────────────

if [[ "${SANITY_CHECK_DISABLE:-false}" == "true" ]]; then
  log_info "SANITY_CHECK_DISABLE=true — skipping all checks"
  exit 0
fi

log_info "── Sanity checks starting ──────────────────────────────────────────"

# ── 1. Required environment variables ────────────────────────────────────────

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
    fail "Required environment variable not set: ${var_name}"
  fi
done

pass "Environment variables present"

# ── 2. Backup mode configuration ─────────────────────────────────────────────

if [[ "${POSTGRES_BACKUP_ALL:-}" == "true" && -n "${POSTGRES_DB:-}" ]]; then
  fail "POSTGRES_DB and POSTGRES_BACKUP_ALL=true are mutually exclusive — set exactly one"
fi

if [[ "${POSTGRES_BACKUP_ALL:-}" != "true" && -z "${POSTGRES_DB:-}" ]]; then
  fail "Neither POSTGRES_DB nor POSTGRES_BACKUP_ALL=true is set — exactly one must be provided"
fi

if [[ "${POSTGRES_BACKUP_ALL:-}" == "true" ]]; then
  pass "Backup mode configuration valid (cluster-wide: pg_dumpall)"
else
  pass "Backup mode configuration valid (single database: ${POSTGRES_DB})"
fi

# ── 3. Cron schedule ─────────────────────────────────────────────────────────

SCHEDULE="${BACKUP_CRON_SCHEDULE:-0 2 * * *}"
# A valid cron expression has exactly 5 whitespace-separated fields.
if ! echo "$SCHEDULE" | grep -qE '^[0-9*/,\-]+ [0-9*/,\-]+ [0-9*/,\-]+ [0-9*/,\-]+ [0-9*/,\-]+$'; then
  fail "BACKUP_CRON_SCHEDULE does not look like a valid 5-field cron expression: '${SCHEDULE}'"
fi

pass "Cron schedule valid: ${SCHEDULE}"

# ── 4. PostgreSQL connectivity ────────────────────────────────────────────────

POSTGRES_PORT="${POSTGRES_PORT:-5432}"
PG_RETRIES="${SANITY_CHECK_PG_RETRIES:-3}"
if ! [[ "$PG_RETRIES" =~ ^[0-9]+$ ]]; then
  fail "SANITY_CHECK_PG_RETRIES must be a positive integer, got: '${PG_RETRIES}'"
fi
# Treat 0 as 1 — zero retries would unconditionally fail the check.
[[ "$PG_RETRIES" -lt 1 ]] && PG_RETRIES=1
PG_RETRY_DELAY="${SANITY_CHECK_PG_RETRY_DELAY:-2}"
if ! [[ "$PG_RETRY_DELAY" =~ ^[0-9]+$ ]]; then
  fail "SANITY_CHECK_PG_RETRY_DELAY must be a non-negative integer, got: '${PG_RETRY_DELAY}'"
fi

export PGPASSWORD="$POSTGRES_PASSWORD"

# 4a. Server reachability — pg_isready checks TCP + postgres protocol handshake
#     without requiring credentials, making it a clean connectivity probe.
pg_ready=false
for ((attempt = 1; attempt <= PG_RETRIES; attempt++)); do
  if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -q 2>/dev/null; then
    pg_ready=true
    break
  fi
  if [[ "$attempt" -lt "$PG_RETRIES" ]]; then
    log_info "PostgreSQL not ready, attempt ${attempt}/${PG_RETRIES} — retrying in ${PG_RETRY_DELAY}s"
    sleep "$PG_RETRY_DELAY"
  fi
done

if [[ "$pg_ready" != "true" ]]; then
  fail "PostgreSQL unreachable at ${POSTGRES_HOST}:${POSTGRES_PORT} after ${PG_RETRIES} attempt(s)"
fi

pass "PostgreSQL reachable at ${POSTGRES_HOST}:${POSTGRES_PORT}"

# 4b. Authentication and database existence — psql performs a real login,
#     catching wrong passwords and missing databases before the first backup.
if [[ "${POSTGRES_BACKUP_ALL:-}" == "true" ]]; then
  auth_target_db="postgres"
else
  auth_target_db="$POSTGRES_DB"
fi

if ! psql -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" \
     -d "$auth_target_db" -c "SELECT 1" -q --no-password >/dev/null 2>&1; then
  if [[ "${POSTGRES_BACKUP_ALL:-}" == "true" ]]; then
    fail "PostgreSQL authentication failed (host: ${POSTGRES_HOST}, user: ${POSTGRES_USER})"
  else
    fail "PostgreSQL authentication failed or database does not exist (host: ${POSTGRES_HOST}, user: ${POSTGRES_USER}, db: ${POSTGRES_DB})"
  fi
fi

if [[ "${POSTGRES_BACKUP_ALL:-}" == "true" ]]; then
  pass "PostgreSQL authentication succeeded (user: ${POSTGRES_USER})"
else
  pass "PostgreSQL authentication succeeded (user: ${POSTGRES_USER}, db: ${POSTGRES_DB})"
fi

# ── 5. S3 connectivity and permissions ───────────────────────────────────────

ENDPOINT_ARGS=()
if [[ -n "${AWS_ENDPOINT_URL:-}" ]]; then
  ENDPOINT_ARGS=("--endpoint-url" "$AWS_ENDPOINT_URL")
fi

S3_PREFIX="${S3_PREFIX:-backups}"

# 5a. Bucket reachability — works against AWS S3 and any S3-compatible provider
#     (Cloudflare R2, MinIO, Backblaze B2, etc.) via the ENDPOINT_ARGS passthrough.
aws_ls_output=$(aws s3 ls "s3://${S3_BUCKET}/" "${ENDPOINT_ARGS[@]}" --max-items 1 2>&1) || {
  [[ -n "$aws_ls_output" ]] && log_error "AWS CLI output: ${aws_ls_output}"
  fail "S3 bucket not accessible: s3://${S3_BUCKET} — check bucket name, credentials, and endpoint"
}

pass "S3 bucket accessible: s3://${S3_BUCKET}"

# 5b. Write permission probe — uploads and immediately removes a sentinel object.
#     Verifies PutObject permission, which is the only S3 permission the backup needs
#     and the one most often misconfigured in IAM policies.
#     Uses the same ENDPOINT_ARGS as the actual backup upload, so it is provider-agnostic.
if [[ "${SANITY_CHECK_SKIP_S3_WRITE_PROBE:-false}" != "true" ]]; then
  PROBE_KEY=".sanity-probe"

  aws_cp_output=$(echo "ok" | aws s3 cp - "s3://${S3_BUCKET}/${PROBE_KEY}" \
      --content-type "text/plain" "${ENDPOINT_ARGS[@]}" 2>&1) || {
    [[ -n "$aws_cp_output" ]] && log_error "AWS CLI output: ${aws_cp_output}"
    fail "S3 write permission check failed: could not upload to s3://${S3_BUCKET}/${PROBE_KEY}"
  }

  # Best-effort cleanup — do not fail if delete fails (some bucket policies allow
  # PutObject but not DeleteObject, which is still sufficient for backups).
  aws s3 rm "s3://${S3_BUCKET}/${PROBE_KEY}" "${ENDPOINT_ARGS[@]}" >/dev/null 2>&1 || true

  pass "S3 write permission confirmed"
else
  log_info "SANITY_CHECK_SKIP_S3_WRITE_PROBE=true — skipping write probe"
fi

# ── 6. Lifecycle hooks (non-fatal) ───────────────────────────────────────────

for hook in /hooks/pre-backup.sh /hooks/post-backup.sh; do
  if [[ -e "$hook" && ! -x "$hook" ]]; then
    warn "$(basename "$hook") exists but is not executable — hook will be skipped at backup time"
  fi
done

# ── Done ──────────────────────────────────────────────────────────────────────

log_info "── All sanity checks passed ────────────────────────────────────────"
