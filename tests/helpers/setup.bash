# tests/helpers/setup.bash
# Shared setup helpers for all unit test files.
# Load from .bats files: load "../helpers/setup"

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_SCRIPT="${REPO_ROOT}/backup.sh"

# Creates a stub binary in $STUB_DIR that:
#   1. Records "echo $@" (space-joined args) to $CALLS_DIR/<name>.args
#   2. Executes <body> as its implementation
#
# Usage: make_stub <name> '<body>'
make_stub() {
  local name="$1"
  local body="${2:-exit 0}"
  local calls_dir="$CALLS_DIR"
  cat >"${STUB_DIR}/${name}" <<STUBEOF
#!/usr/bin/env bash
echo "\$@" >>"${calls_dir}/${name}.args"
${body}
STUBEOF
  chmod +x "${STUB_DIR}/${name}"
}

setup_common() {
  # Per-test isolated dirs (bats provides BATS_TEST_TMPDIR, unique per test)
  export STUB_DIR="${BATS_TEST_TMPDIR}/stubs"
  export CALLS_DIR="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "$STUB_DIR" "$CALLS_DIR"

  # Inject stubs first in PATH so they shadow real binaries
  export PATH="${STUB_DIR}:${PATH}"

  # Default stubs (no-op) — tests override as needed
  make_stub gzip 'cat'
  make_stub pg_dump 'echo "-- mock dump"'
  make_stub pg_dumpall 'echo "-- mock dumpall"'
  make_stub aws ''

  # Required env vars — valid defaults
  export POSTGRES_HOST="localhost"
  export POSTGRES_USER="testuser"
  export POSTGRES_PASSWORD="testpass"
  export POSTGRES_PORT="5432"
  export S3_BUCKET="test-bucket"
  export AWS_ACCESS_KEY_ID="test-access-key"
  export AWS_SECRET_ACCESS_KEY="test-secret-key"
  export AWS_DEFAULT_REGION="us-east-1"

  # Default: single DB mode
  export POSTGRES_DB="testdb"
  unset POSTGRES_BACKUP_ALL  2>/dev/null || true
  unset POSTGRES_EXTRA_OPTS  2>/dev/null || true
  unset S3_PREFIX            2>/dev/null || true
  unset AWS_ENDPOINT_URL     2>/dev/null || true
}

teardown_common() {
  :  # bats automatically removes BATS_TEST_TMPDIR after each test
}

# ── Assertion helpers ─────────────────────────────────────────────────────────

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected to contain: '${needle}'"
    echo "Actual:              '${haystack}'"
    return 1
  fi
}

assert_called() {
  local name="$1"
  if [[ ! -s "${CALLS_DIR}/${name}.args" ]]; then
    echo "Expected '${name}' to have been called, but it was not."
    return 1
  fi
}

assert_not_called() {
  local name="$1"
  if [[ -s "${CALLS_DIR}/${name}.args" ]]; then
    echo "Expected '${name}' NOT to be called, but it was."
    echo "Recorded args: $(cat "${CALLS_DIR}/${name}.args")"
    return 1
  fi
}

mock_args() {
  local name="$1"
  head -1 "${CALLS_DIR}/${name}.args" 2>/dev/null || echo ""
}

assert_args_contain() {
  local name="$1"
  local needle="$2"
  local recorded
  recorded=$(cat "${CALLS_DIR}/${name}.args" 2>/dev/null || echo "")
  if [[ "$recorded" != *"$needle"* ]]; then
    echo "Expected '${name}' args to contain: '${needle}'"
    echo "Recorded args: '${recorded}'"
    return 1
  fi
}
