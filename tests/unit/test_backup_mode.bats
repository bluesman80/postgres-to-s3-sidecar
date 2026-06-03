#!/usr/bin/env bats
# tests/unit/test_backup_mode.bats
# Backup mode selection (pg_dump vs pg_dumpall), filename conventions, extra opts

bats_require_minimum_version 1.5.0

load "../helpers/setup"

setup()    { setup_common; }
teardown() { teardown_common; }

@test "single DB mode calls pg_dump" {
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_called "pg_dump"
}

@test "single DB mode does NOT call pg_dumpall" {
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_not_called "pg_dumpall"
}

@test "single DB mode passes host to pg_dump" {
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "pg_dump" "-h localhost"
}

@test "single DB mode passes port to pg_dump" {
  export POSTGRES_PORT="5555"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "pg_dump" "-p 5555"
}

@test "single DB mode passes user to pg_dump" {
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "pg_dump" "-U testuser"
}

@test "single DB mode passes database name to pg_dump" {
  export POSTGRES_DB="mydb"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "pg_dump" "mydb"
}

@test "single DB mode uses custom format flag -F c" {
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "pg_dump" "-F c"
}

@test "single DB mode upload key contains database name" {
  export POSTGRES_DB="mydb"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "aws" "mydb_"
}

@test "single DB mode upload key has .dump.gz extension" {
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "aws" ".dump.gz"
}

@test "all DBs mode calls pg_dumpall" {
  unset POSTGRES_DB
  export POSTGRES_BACKUP_ALL="true"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_called "pg_dumpall"
}

@test "all DBs mode does NOT call pg_dump" {
  unset POSTGRES_DB
  export POSTGRES_BACKUP_ALL="true"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_not_called "pg_dump"
}

@test "all DBs mode passes host to pg_dumpall" {
  unset POSTGRES_DB
  export POSTGRES_BACKUP_ALL="true"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "pg_dumpall" "-h localhost"
}

@test "all DBs mode upload key has all_ prefix and .sql.gz extension" {
  unset POSTGRES_DB
  export POSTGRES_BACKUP_ALL="true"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "aws" "all_"
  assert_args_contain "aws" ".sql.gz"
}

@test "POSTGRES_EXTRA_OPTS are forwarded to pg_dump" {
  export POSTGRES_EXTRA_OPTS="--exclude-table-data=logs --schema=public"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "pg_dump" "--exclude-table-data=logs"
  assert_args_contain "pg_dump" "--schema=public"
}

@test "default port 5432 used when POSTGRES_PORT is not set" {
  unset POSTGRES_PORT
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "pg_dump" "-p 5432"
}

@test "upload key contains a timestamp in YYYYMMDD_HHMMSS format" {
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  local aws_args
  aws_args=$(mock_args "aws")
  [[ "$aws_args" =~ [0-9]{8}_[0-9]{6} ]]
}
