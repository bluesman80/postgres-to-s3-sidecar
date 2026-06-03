#!/usr/bin/env bash
# tests/integration/run.sh
# Integration test runner. Builds the sidecar image, spins up postgres+minio,
# runs backup scenarios, asserts files land in the bucket, tears down.
#
# Usage:
#   ./tests/integration/run.sh [PG_VERSION]
#   PG_VERSION defaults to 18.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PG_VERSION="${1:-18}"
IMAGE="postgres-s3-backup:test-${PG_VERSION}"
AWS_CLI_IMAGE="${AWS_CLI_IMAGE:-amazon/aws-cli:2.34.59}"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
COMPOSE_PROJECT="pg-s3-test-${PG_VERSION}-$$"
HOOKS_DIR="${SCRIPT_DIR}/hooks"
PASS=0
FAIL=0

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { log "  PASS: $1"; PASS=$((PASS+1)); }
fail() { log "  FAIL: $1"; FAIL=$((FAIL+1)); }

cleanup() {
  log "Tearing down compose project: ${COMPOSE_PROJECT}"
  PG_VERSION="$PG_VERSION" docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

# ─── Build image ──────────────────────────────────────────────────────────────
log "Building image ${IMAGE} (PG_VERSION=${PG_VERSION})..."
docker build \
  --build-arg PG_VERSION="${PG_VERSION}" \
  -t "${IMAGE}" \
  "${REPO_ROOT}" >/dev/null

# ─── Start infrastructure ─────────────────────────────────────────────────────
log "Starting postgres + minio (compose project: ${COMPOSE_PROJECT})..."
PG_VERSION="$PG_VERSION" docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
  up -d postgres minio

log "Waiting for postgres to be healthy..."
for i in $(seq 1 30); do
  if PG_VERSION="$PG_VERSION" docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
       exec -T postgres pg_isready -U testuser -d testdb >/dev/null 2>&1; then
    log "Postgres ready."
    break
  fi
  [ "$i" -eq 30 ] && { log "Postgres never became ready"; exit 1; }
  sleep 2
done

log "Waiting for minio to be healthy..."
for i in $(seq 1 30); do
  if PG_VERSION="$PG_VERSION" docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
       exec -T minio mc ready local >/dev/null 2>&1; then
    log "MinIO ready."
    break
  fi
  [ "$i" -eq 30 ] && { log "MinIO never became ready"; exit 1; }
  sleep 2
done

# Create bucket
PG_VERSION="$PG_VERSION" docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
  run --rm createbucket >/dev/null

# ─── Helper: run backup container and return the S3 key of the uploaded file ──
run_backup() {
  local extra_env=("$@")
  # Returns the S3 key on stdout (last line of backup log matching "uploaded to")
  docker run --rm \
    --network "${COMPOSE_PROJECT}_default" \
    "${extra_env[@]}" \
    -e POSTGRES_HOST=postgres \
    -e POSTGRES_PORT=5432 \
    -e POSTGRES_USER=testuser \
    -e POSTGRES_PASSWORD=testpass \
    -e S3_BUCKET=test-bucket \
    -e AWS_ACCESS_KEY_ID=minioadmin \
    -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_DEFAULT_REGION=us-east-1 \
    -e AWS_ENDPOINT_URL=http://minio:9000 \
    "${IMAGE}" \
    bash /backup.sh 2>&1
}

assert_s3_object_exists() {
  local key="$1"
  docker run --rm \
    --network "${COMPOSE_PROJECT}_default" \
    -e AWS_ACCESS_KEY_ID=minioadmin \
    -e AWS_SECRET_ACCESS_KEY=minioadmin \
    -e AWS_DEFAULT_REGION=us-east-1 \
    "${AWS_CLI_IMAGE}" \
    s3 ls "s3://test-bucket/${key}" \
      --endpoint-url http://minio:9000 >/dev/null 2>&1
}

extract_s3_key() {
  # Parse "uploaded to s3://test-bucket/<key>" from backup output.
  # Uses sed (POSIX) instead of grep -P so this works on macOS (BSD grep).
  echo "$1" | sed -n 's|.*s3://test-bucket/\([^ ]*\).*|\1|p' | tail -1
}

# ─── Test 1: Single DB backup ─────────────────────────────────────────────────
log "TEST 1: Single database backup (POSTGRES_DB)"
output=$(run_backup -e POSTGRES_DB=testdb)
key=$(extract_s3_key "$output")
if echo "$key" | grep -q "testdb_" && echo "$key" | grep -q ".dump.gz"; then
  if assert_s3_object_exists "$key"; then
    pass "Single DB backup: file '${key}' exists in bucket"
  else
    fail "Single DB backup: file '${key}' not found in bucket"
  fi
else
  fail "Single DB backup: unexpected key format '${key}'"
fi

# ─── Test 2: All DBs backup ───────────────────────────────────────────────────
log "TEST 2: Cluster-wide backup (POSTGRES_BACKUP_ALL=true)"
output=$(run_backup -e POSTGRES_BACKUP_ALL=true)
key=$(extract_s3_key "$output")
if echo "$key" | grep -q "all_" && echo "$key" | grep -q ".sql.gz"; then
  if assert_s3_object_exists "$key"; then
    pass "All DBs backup: file '${key}' exists in bucket"
  else
    fail "All DBs backup: file '${key}' not found in bucket"
  fi
else
  fail "All DBs backup: unexpected key format '${key}'"
fi

# ─── Test 3: Custom S3_PREFIX ─────────────────────────────────────────────────
log "TEST 3: Custom S3_PREFIX"
output=$(run_backup -e POSTGRES_DB=testdb -e S3_PREFIX=custom/prefix)
key=$(extract_s3_key "$output")
if echo "$key" | grep -q "custom/prefix/"; then
  if assert_s3_object_exists "$key"; then
    pass "Custom prefix: file '${key}' exists under custom/prefix/"
  else
    fail "Custom prefix: file '${key}' not found in bucket"
  fi
else
  fail "Custom prefix: expected 'custom/prefix/' in key, got '${key}'"
fi

# ─── Test 4: Post-backup hook ─────────────────────────────────────────────────
log "TEST 4: Post-backup hook execution"
HOOK_SENTINEL="/tmp/hook_sentinel_${COMPOSE_PROJECT}"
HOOK_DIR_TMP="$(mktemp -d)"
cat > "${HOOK_DIR_TMP}/post-backup.sh" <<'HOOKEOF'
#!/bin/bash
touch /tmp/post_hook_ran
HOOKEOF
chmod +x "${HOOK_DIR_TMP}/post-backup.sh"

output=$(docker run --rm \
  --network "${COMPOSE_PROJECT}_default" \
  -e POSTGRES_HOST=postgres \
  -e POSTGRES_PORT=5432 \
  -e POSTGRES_USER=testuser \
  -e POSTGRES_PASSWORD=testpass \
  -e POSTGRES_DB=testdb \
  -e S3_BUCKET=test-bucket \
  -e AWS_ACCESS_KEY_ID=minioadmin \
  -e AWS_SECRET_ACCESS_KEY=minioadmin \
  -e AWS_DEFAULT_REGION=us-east-1 \
  -e AWS_ENDPOINT_URL=http://minio:9000 \
  -v "${HOOK_DIR_TMP}:/hooks" \
  "${IMAGE}" \
  bash /backup.sh 2>&1)
rm -rf "$HOOK_DIR_TMP"

if echo "$output" | grep -q "post-backup"; then
  pass "Post-backup hook: log confirms hook execution"
else
  fail "Post-backup hook: log did not mention post-backup hook"
fi

# ─── Test 5: File is valid gzip ───────────────────────────────────────────────
log "TEST 5: Uploaded file is a valid gzip archive"
output=$(run_backup -e POSTGRES_DB=testdb)
key=$(extract_s3_key "$output")
# Stream the file from MinIO to stdout, pipe into gzip -t — no temp file on host
if docker run --rm \
     --network "${COMPOSE_PROJECT}_default" \
     -e AWS_ACCESS_KEY_ID=minioadmin \
     -e AWS_SECRET_ACCESS_KEY=minioadmin \
     -e AWS_DEFAULT_REGION=us-east-1 \
     "${AWS_CLI_IMAGE}" \
     s3 cp "s3://test-bucket/${key}" - \
       --endpoint-url http://minio:9000 2>/dev/null | gzip -t 2>/dev/null; then
  pass "Gzip integrity: downloaded file passes gzip -t"
else
  fail "Gzip integrity: downloaded file is not a valid gzip archive"
fi

# ─── Test 6: Restore roundtrip ────────────────────────────────────────────────
log "TEST 6: Restore roundtrip (single DB)"
# Create a test table in the source DB
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
  exec -T postgres \
  psql -U testuser -d testdb -c \
  "CREATE TABLE IF NOT EXISTS integration_test (id serial primary key, val text);" >/dev/null
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
  exec -T postgres \
  psql -U testuser -d testdb -c \
  "INSERT INTO integration_test (val) VALUES ('hello') ON CONFLICT DO NOTHING;" >/dev/null

# Run backup
output=$(run_backup -e POSTGRES_DB=testdb)
key=$(extract_s3_key "$output")

# Create fresh target database
docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
  exec -T postgres \
  psql -U testuser -d testdb -c "CREATE DATABASE restore_test;" >/dev/null 2>&1 || true

# Stream dump from MinIO → gunzip → pg_restore, entirely via docker pipelines
# No temp files on host — avoids root-ownership permission issues
docker run --rm \
  --network "${COMPOSE_PROJECT}_default" \
  -e AWS_ACCESS_KEY_ID=minioadmin \
  -e AWS_SECRET_ACCESS_KEY=minioadmin \
  -e AWS_DEFAULT_REGION=us-east-1 \
  "${AWS_CLI_IMAGE}" \
  s3 cp "s3://test-bucket/${key}" - \
    --endpoint-url http://minio:9000 2>/dev/null \
| gunzip -c \
| docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
    exec -T postgres \
    env PGPASSWORD=testpass pg_restore -h localhost -U testuser -d restore_test --no-privileges --no-owner 2>/dev/null || true

# Verify restored data
result=$(docker compose -f "$COMPOSE_FILE" -p "$COMPOSE_PROJECT" \
  exec -T postgres \
  psql -U testuser -d restore_test -tAc \
  "SELECT COUNT(*) FROM integration_test WHERE val='hello';" 2>/dev/null || echo "0")
result="${result//[$'\t\r\n ']/}"  # strip whitespace

if [ "${result:-0}" -ge 1 ]; then
  pass "Restore roundtrip: data present in restored database"
else
  fail "Restore roundtrip: data not found after restore (result='${result}')"
fi

# ─── Results ──────────────────────────────────────────────────────────────────
echo ""
log "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
