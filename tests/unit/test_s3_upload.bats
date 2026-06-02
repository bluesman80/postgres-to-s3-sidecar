#!/usr/bin/env bats
# tests/unit/test_s3_upload.bats
# S3 upload: prefix, endpoint, key format, subcommand

bats_require_minimum_version 1.5.0

load "../helpers/setup"

setup()    { setup_common; }
teardown() { teardown_common; }

@test "aws s3 cp is called" {
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_called "aws"
  assert_args_contain "aws" "s3 cp"
}

@test "upload target starts with s3://S3_BUCKET/" {
  export S3_BUCKET="my-backup-bucket"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "aws" "s3://my-backup-bucket/"
}

@test "default S3_PREFIX is 'backups'" {
  unset S3_PREFIX
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "aws" "s3://test-bucket/backups/"
}

@test "custom S3_PREFIX is used in the upload key" {
  export S3_PREFIX="pg-backups/prod"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "aws" "pg-backups/prod/"
}

@test "no --endpoint-url flag when AWS_ENDPOINT_URL is not set" {
  unset AWS_ENDPOINT_URL
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  local aws_args
  aws_args=$(mock_args "aws")
  [[ "$aws_args" != *"--endpoint-url"* ]]
}

@test "--endpoint-url is passed when AWS_ENDPOINT_URL is set" {
  export AWS_ENDPOINT_URL="http://minio:9000"
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_args_contain "aws" "--endpoint-url"
  assert_args_contain "aws" "http://minio:9000"
}

@test "aws failure causes backup to exit non-zero" {
  make_stub aws 'exit 1'
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -ne 0 ]
}

@test "log output confirms upload success" {
  run --separate-stderr bash "$BACKUP_SCRIPT"
  [ "$status" -eq 0 ]
  assert_contains "$output" "uploaded to s3://"
}
