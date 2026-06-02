#!/usr/bin/env bats
# tests/unit/test_hooks.bats
# Lifecycle hook execution (pre-backup.sh and post-backup.sh)
#
# Strategy: backup.sh hardcodes /hooks. We create a patched copy per test
# that substitutes /hooks with a temp dir (no root required).

bats_require_minimum_version 1.5.0

load "../helpers/setup"

setup() {
  setup_common

  # Hooks dir isolated per test
  export HOOKS_DIR="${BATS_TEST_TMPDIR}/hooks"
  mkdir -p "$HOOKS_DIR"

  # Create a patched backup.sh that uses HOOKS_DIR instead of /hooks
  export TEST_BACKUP_SCRIPT="${BATS_TEST_TMPDIR}/backup_patched.sh"
  sed "s|/hooks|${HOOKS_DIR}|g" "$BACKUP_SCRIPT" > "$TEST_BACKUP_SCRIPT"
  chmod +x "$TEST_BACKUP_SCRIPT"
}

teardown() { teardown_common; }

@test "pre-backup hook runs when present and executable" {
  local sentinel="${BATS_TEST_TMPDIR}/pre_ran"
  printf '#!/bin/bash\ntouch "%s"\n' "$sentinel" > "${HOOKS_DIR}/pre-backup.sh"
  chmod +x "${HOOKS_DIR}/pre-backup.sh"

  run --separate-stderr bash "$TEST_BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$sentinel" ]
}

@test "post-backup hook runs when present and executable" {
  local sentinel="${BATS_TEST_TMPDIR}/post_ran"
  printf '#!/bin/bash\ntouch "%s"\n' "$sentinel" > "${HOOKS_DIR}/post-backup.sh"
  chmod +x "${HOOKS_DIR}/post-backup.sh"

  run --separate-stderr bash "$TEST_BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$sentinel" ]
}

@test "pre-backup hook is skipped when not executable" {
  local sentinel="${BATS_TEST_TMPDIR}/pre_ran"
  printf '#!/bin/bash\ntouch "%s"\n' "$sentinel" > "${HOOKS_DIR}/pre-backup.sh"
  # intentionally NOT chmod +x

  run --separate-stderr bash "$TEST_BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$sentinel" ]
}

@test "post-backup hook is skipped when not executable" {
  local sentinel="${BATS_TEST_TMPDIR}/post_ran"
  printf '#!/bin/bash\ntouch "%s"\n' "$sentinel" > "${HOOKS_DIR}/post-backup.sh"
  # intentionally NOT chmod +x

  run --separate-stderr bash "$TEST_BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  [ ! -f "$sentinel" ]
}

@test "backup succeeds when no hooks are present" {
  # HOOKS_DIR is empty
  run --separate-stderr bash "$TEST_BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "log mentions pre-backup hook when it runs" {
  printf '#!/bin/bash\nexit 0\n' > "${HOOKS_DIR}/pre-backup.sh"
  chmod +x "${HOOKS_DIR}/pre-backup.sh"

  run --separate-stderr bash "$TEST_BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "pre-backup"
}

@test "log mentions post-backup hook when it runs" {
  printf '#!/bin/bash\nexit 0\n' > "${HOOKS_DIR}/post-backup.sh"
  chmod +x "${HOOKS_DIR}/post-backup.sh"

  run --separate-stderr bash "$TEST_BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "post-backup"
}

@test "pre-backup hook failure aborts the backup" {
  printf '#!/bin/bash\nexit 42\n' > "${HOOKS_DIR}/pre-backup.sh"
  chmod +x "${HOOKS_DIR}/pre-backup.sh"

  run --separate-stderr bash "$TEST_BACKUP_SCRIPT"
  [ "$status" -ne 0 ]
}
