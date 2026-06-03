# Testing

This directory contains the full test suite for `postgres-s3-backup`. There are two layers: fast unit tests that run offline with mocked binaries, and integration tests that spin up real PostgreSQL and MinIO containers.

---

## Directory Structure

```
tests/
├── helpers/
│   └── setup.bash          # Shared bats helpers: make_stub, assertions, setup_common
├── integration/
│   ├── docker-compose.yml  # Postgres + MinIO + bucket-creation sidecar
│   └── run.sh              # Integration test runner script
└── unit/
    ├── test_backup_mode.bats    # pg_dump vs pg_dumpall selection, flags, filenames
    ├── test_env_validation.bats # Required env var checks, mutual exclusion
    ├── test_hooks.bats          # pre-backup / post-backup lifecycle hooks
    └── test_s3_upload.bats      # S3 key prefix, endpoint URL, upload behaviour
```

---

## Unit Tests

### Prerequisites

- **bash** (≥ 4)
- **[bats-core](https://github.com/bats-core/bats-core)** v1.5 or later

Install bats-core (no root required):

```bash
git clone --depth 1 https://github.com/bats-core/bats-core.git /tmp/bats-core
/tmp/bats-core/install.sh ~/.local
export PATH="$HOME/.local/bin:$PATH"
```

### Running

Run all unit tests:

```bash
bats tests/unit/
```

Run a single file:

```bash
bats tests/unit/test_env_validation.bats
```

Run with verbose failure output:

```bash
bats tests/unit/ --print-output-on-failure
```

### What Is Tested

| File | Tests | Coverage |
|---|---|---|
| `test_env_validation.bats` | 11 | Every required env var missing exits 1 with the var name in output; mutual exclusion between `POSTGRES_DB` and `POSTGRES_BACKUP_ALL=true`; both success paths |
| `test_backup_mode.bats` | 16 | Single-DB mode calls `pg_dump` (not `pg_dumpall`) with correct `-h`, `-p`, `-U`, `-F c`, and DB name; all-DBs mode calls `pg_dumpall`; upload key filename convention (`.dump.gz` vs `all_*.sql.gz`); `POSTGRES_EXTRA_OPTS` forwarded; default port 5432; timestamp in upload key |
| `test_s3_upload.bats` | 8 | `aws s3 cp` called; upload target includes `s3://BUCKET/`; default prefix `backups/`; custom `S3_PREFIX`; `--endpoint-url` absent/present based on `AWS_ENDPOINT_URL`; `aws` failure aborts script; success log message |
| `test_hooks.bats` | 8 | Pre- and post-backup hooks run when executable; skipped when not executable; backup succeeds with no hooks; log confirms hook execution; pre-backup failure aborts backup |

### How It Works

`backup.sh` calls `pg_dump`, `pg_dumpall`, `aws`, and `gzip`. The unit tests never invoke real binaries — instead, `setup_common` (from `helpers/setup.bash`) creates lightweight stub scripts in a per-test temp directory and prepends it to `$PATH`.

Each stub records its arguments to `$CALLS_DIR/<name>.args` (space-joined, one call per line) and then executes a configurable body. Assertion helpers read these files:

```
assert_called "pg_dump"            # was pg_dump called at all?
assert_not_called "pg_dumpall"     # was pg_dumpall NOT called?
assert_args_contain "aws" "--endpoint-url http://minio:9000"
```

The `test_hooks.bats` file cannot bind-mount `/hooks` without root, so it creates a patched copy of `backup.sh` via `sed` that substitutes the hardcoded `/hooks` path with a per-test temp directory.

---

## Integration Tests

### Prerequisites

- **Docker** (with the Compose plugin, v2)
- Internet access on first run to pull `postgres`, `minio/minio`, `minio/mc`, and `amazon/aws-cli` images

No local PostgreSQL or AWS credentials are needed.

### Running

Run against the default PG version (18):

```bash
bash tests/integration/run.sh
```

Run against a specific PostgreSQL major version:

```bash
bash tests/integration/run.sh 16
```

The script builds a local Docker image (`postgres-s3-backup:test-<PG_VERSION>`), starts Postgres and MinIO, runs all scenarios, reports results, and tears everything down on exit — including on failure.

### What Is Tested

| Test | What it verifies |
|---|---|
| Single DB backup | `backup.sh` with `POSTGRES_DB=testdb` produces `testdb_<timestamp>.dump.gz` under `backups/` in the MinIO bucket |
| Cluster-wide backup | `POSTGRES_BACKUP_ALL=true` produces `all_<timestamp>.sql.gz` under `backups/` |
| Custom `S3_PREFIX` | File lands under the custom prefix key path |
| Post-backup hook | A bind-mounted `post-backup.sh` is executed; log confirms it ran |
| Gzip integrity | Downloaded backup file passes `gzip -t` (valid compressed archive) |
| Restore roundtrip | A table with data is dumped, uploaded, streamed back through `pg_restore` into a fresh database, and the data is verified to be present |

### How It Works

`run.sh` orchestrates everything with plain `docker` and `docker compose` calls:

1. **Builds** the sidecar image with the target `PG_VERSION` build arg.
2. **Starts** `postgres` and `minio` services and health-checks both.
3. **Creates** a `test-bucket` bucket via the `minio/mc` container.
4. **Runs** `backup.sh` directly inside a `docker run` container on the same network as postgres and minio, with `AWS_ENDPOINT_URL` pointing at the local MinIO.
5. **Asserts** file presence by listing the bucket with `amazon/aws-cli`.
6. **Restore test**: streams the backup from MinIO via `aws s3 cp ... -` (stdout), pipes through `gunzip`, pipes into `pg_restore` running inside the postgres container via `docker compose exec -T`. No temp files are written to the host (avoids root-ownership issues with Docker volumes).
7. **Tears down** the compose project and named volumes on exit.

---

## CI

The GitHub Actions workflow at `.github/workflows/test.yml` runs on every pull request and push to `main`:

- **`unit` job** — installs bats-core and runs `bats tests/unit/`
- **`integration` job** — matrix across PostgreSQL versions 13, 14, 15, 16, 17, 18; each runs `bash tests/integration/run.sh <version>`

The matrix uses `fail-fast: false` so a failure in one PG version does not cancel the others.
