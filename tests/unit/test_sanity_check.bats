#!/usr/bin/env bats
# tests/unit/test_sanity_check.bats
# Startup sanity checks in sanity_check.sh

bats_require_minimum_version 1.5.0

load "../helpers/setup"

SANITY_SCRIPT="${REPO_ROOT}/sanity_check.sh"

setup() {
  setup_common

  # Additional stubs needed by sanity_check.sh but not backup.sh
  make_stub pg_isready ''
  make_stub psql ''

  # Unset opt-out flags so each test starts from a clean baseline
  unset SANITY_CHECK_DISABLE             2>/dev/null || true
  unset SANITY_CHECK_SKIP_S3_WRITE_PROBE 2>/dev/null || true
  unset SANITY_CHECK_PG_RETRIES          2>/dev/null || true
  unset SANITY_CHECK_PG_RETRY_DELAY      2>/dev/null || true
}

teardown() { teardown_common; }

# ── Opt-out ───────────────────────────────────────────────────────────────────

@test "SANITY_CHECK_DISABLE=true exits 0 and skips all checks" {
  export SANITY_CHECK_DISABLE="true"
  make_stub pg_isready 'exit 1'
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 0 ]
  assert_contains "$output$stderr" "SANITY_CHECK_DISABLE=true"
  assert_not_called "pg_isready"
}

# ── Environment variable validation ───────────────────────────────────────────

@test "exits 1 when POSTGRES_HOST is missing" {
  unset POSTGRES_HOST
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "POSTGRES_HOST"
}

@test "exits 1 when POSTGRES_PASSWORD is missing" {
  unset POSTGRES_PASSWORD
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "POSTGRES_PASSWORD"
}

@test "exits 1 when S3_BUCKET is missing" {
  unset S3_BUCKET
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "S3_BUCKET"
}

@test "exits 1 when AWS_ACCESS_KEY_ID is missing" {
  unset AWS_ACCESS_KEY_ID
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "AWS_ACCESS_KEY_ID"
}

# ── Backup mode validation ────────────────────────────────────────────────────

@test "exits 1 when both POSTGRES_DB and POSTGRES_BACKUP_ALL=true are set" {
  export POSTGRES_DB="mydb"
  export POSTGRES_BACKUP_ALL="true"
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "mutually exclusive"
}

@test "exits 1 when neither POSTGRES_DB nor POSTGRES_BACKUP_ALL is set" {
  unset POSTGRES_DB
  unset POSTGRES_BACKUP_ALL
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "exactly one must be provided"
}

# ── Cron schedule validation ──────────────────────────────────────────────────

@test "exits 1 when BACKUP_CRON_SCHEDULE has wrong field count" {
  export BACKUP_CRON_SCHEDULE="0 2 * *"   # only 4 fields
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "5-field cron expression"
}

@test "passes with a valid non-default cron schedule" {
  export BACKUP_CRON_SCHEDULE="30 4 * * 1"
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "[PASS] Cron schedule valid: 30 4 * * 1"
}

# ── PostgreSQL connectivity ───────────────────────────────────────────────────

@test "exits 1 when PostgreSQL is unreachable after all retries" {
  make_stub pg_isready 'exit 2'   # exit 2 = no response (timeout)
  export SANITY_CHECK_PG_RETRIES="2"
  export SANITY_CHECK_PG_RETRY_DELAY="0"
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "unreachable"
  assert_contains "$output$stderr" "2 attempt"
}

@test "exits 1 when psql authentication fails" {
  make_stub psql 'exit 1'
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "authentication failed"
}

@test "pg_isready is called with correct host and port but no credentials" {
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "pg_isready" "-h localhost"
  assert_args_contain "pg_isready" "-p 5432"
  # pg_isready connectivity check must NOT pass credentials — it only checks
  # server readiness, not auth; credentials are validated by the psql call.
  local pg_args
  pg_args=$(cat "${CALLS_DIR}/pg_isready.args" 2>/dev/null || echo "")
  [[ "$pg_args" != *"-U"* ]]
}

@test "psql is called with correct host, port, user, and database" {
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "psql" "-h localhost"
  assert_args_contain "psql" "-p 5432"
  assert_args_contain "psql" "-U testuser"
  assert_args_contain "psql" "-d testdb"
}

# ── S3 connectivity ───────────────────────────────────────────────────────────

@test "exits 1 when aws s3 ls fails (bucket not accessible)" {
  make_stub aws 'exit 1'
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "not accessible"
}

@test "exits 1 when write probe upload fails" {
  # First aws call (s3 ls) succeeds; subsequent call (s3 cp) fails.
  cat >"${STUB_DIR}/aws" <<STUBEOF
#!/usr/bin/env bash
echo "\$@" >> "${CALLS_DIR}/aws.args"
if echo "\$@" | grep -q "s3 cp"; then
  exit 1
fi
exit 0
STUBEOF
  chmod +x "${STUB_DIR}/aws"
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "write permission check failed"
}

@test "SANITY_CHECK_SKIP_S3_WRITE_PROBE=true skips write probe" {
  export SANITY_CHECK_SKIP_S3_WRITE_PROBE="true"
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 0 ]
  local aws_calls
  aws_calls=$(cat "${CALLS_DIR}/aws.args" 2>/dev/null || echo "")
  [[ "$aws_calls" != *"s3 cp"* ]]
  assert_contains "$output" "skipping write probe"
}

@test "--endpoint-url is forwarded to aws when AWS_ENDPOINT_URL is set" {
  export AWS_ENDPOINT_URL="http://minio:9000"
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "aws" "--endpoint-url"
  assert_args_contain "aws" "http://minio:9000"
}

@test "no --endpoint-url flag when AWS_ENDPOINT_URL is not set" {
  unset AWS_ENDPOINT_URL
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 0 ]
  local aws_args
  aws_args=$(cat "${CALLS_DIR}/aws.args" 2>/dev/null || echo "")
  [[ "$aws_args" != *"--endpoint-url"* ]]
}

# ── Hooks ─────────────────────────────────────────────────────────────────────

@test "warns when pre-backup.sh exists but is not executable" {
  local hooks_dir="${BATS_TEST_TMPDIR}/hooks"
  mkdir -p "$hooks_dir"
  touch "${hooks_dir}/pre-backup.sh"   # not chmod +x

  # Patch the hardcoded /hooks path (same technique as test_hooks.bats)
  local patched="${BATS_TEST_TMPDIR}/sanity_check_patched.sh"
  sed "s|/hooks|${hooks_dir}|g" "$SANITY_SCRIPT" > "$patched"

  run --separate-stderr bash "$patched"
  [ "$status" -eq 0 ]
  assert_contains "$output$stderr" "not executable"
  assert_contains "$output$stderr" "pre-backup.sh"
}

@test "no warning when hooks do not exist" {
  local hooks_dir="${BATS_TEST_TMPDIR}/hooks_empty"
  mkdir -p "$hooks_dir"
  local patched="${BATS_TEST_TMPDIR}/sanity_check_patched.sh"
  sed "s|/hooks|${hooks_dir}|g" "$SANITY_SCRIPT" > "$patched"

  run --separate-stderr bash "$patched"
  [ "$status" -eq 0 ]
  [[ "$output$stderr" != *"not executable"* ]]
}

# ── Happy path ────────────────────────────────────────────────────────────────

@test "all checks pass: exits 0 and prints final summary line" {
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "All sanity checks passed"
}

@test "log output includes [PASS] prefix for each check" {
  run --separate-stderr bash "$SANITY_SCRIPT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "[PASS] Environment variables present"
  assert_contains "$output" "[PASS] Backup mode configuration valid"
  assert_contains "$output" "[PASS] Cron schedule valid"
  assert_contains "$output" "[PASS] PostgreSQL reachable"
  assert_contains "$output" "[PASS] PostgreSQL authentication succeeded"
  assert_contains "$output" "[PASS] S3 bucket accessible"
  assert_contains "$output" "[PASS] S3 write permission confirmed"
}
