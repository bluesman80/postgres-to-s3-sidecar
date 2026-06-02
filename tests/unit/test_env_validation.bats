#!/usr/bin/env bats
# tests/unit/test_env_validation.bats
# Required env var validation in backup.sh

bats_require_minimum_version 1.5.0

load "../helpers/setup"

setup()    { setup_common; }
teardown() { teardown_common; }

@test "exits 1 when POSTGRES_HOST is missing" {
  unset POSTGRES_HOST
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "POSTGRES_HOST"
}

@test "exits 1 when POSTGRES_USER is missing" {
  unset POSTGRES_USER
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "POSTGRES_USER"
}

@test "exits 1 when POSTGRES_PASSWORD is missing" {
  unset POSTGRES_PASSWORD
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "POSTGRES_PASSWORD"
}

@test "exits 1 when S3_BUCKET is missing" {
  unset S3_BUCKET
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "S3_BUCKET"
}

@test "exits 1 when AWS_ACCESS_KEY_ID is missing" {
  unset AWS_ACCESS_KEY_ID
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "AWS_ACCESS_KEY_ID"
}

@test "exits 1 when AWS_SECRET_ACCESS_KEY is missing" {
  unset AWS_SECRET_ACCESS_KEY
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "AWS_SECRET_ACCESS_KEY"
}

@test "exits 1 when AWS_DEFAULT_REGION is missing" {
  unset AWS_DEFAULT_REGION
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "AWS_DEFAULT_REGION"
}

@test "exits 1 when both POSTGRES_DB and POSTGRES_BACKUP_ALL=true are set" {
  export POSTGRES_DB="mydb"
  export POSTGRES_BACKUP_ALL="true"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "mutually exclusive"
}

@test "exits 1 when neither POSTGRES_DB nor POSTGRES_BACKUP_ALL is set" {
  unset POSTGRES_DB
  unset POSTGRES_BACKUP_ALL
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 1 ]
  assert_contains "$output$stderr" "Exactly one must be provided"
}

@test "succeeds with all required vars and POSTGRES_DB set" {
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "succeeds with all required vars and POSTGRES_BACKUP_ALL=true" {
  unset POSTGRES_DB
  export POSTGRES_BACKUP_ALL="true"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
}
