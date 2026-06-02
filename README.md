# postgres-s3-backup

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg) ![PostgreSQL](https://img.shields.io/badge/PostgreSQL-13--18-336791?logo=postgresql&logoColor=white) ![Docker](https://img.shields.io/badge/Docker-ready-2496ED?logo=docker&logoColor=white)

A Docker sidecar that automatically dumps a PostgreSQL database and uploads the backup to any S3-compatible storage on a configurable cron schedule.

---

## What It Does

`postgres-s3-backup` runs alongside your PostgreSQL container, takes scheduled dumps using `pg_dump` or `pg_dumpall`, compresses them with gzip, and ships them straight to an S3 bucket. It supports PostgreSQL 13 through 18 via separate Docker images, each bundling the exact matching `pg_dump` binary. Drop it into any `docker-compose.yml` stack with a handful of environment variables and your backups run on autopilot.

---

## Features

- **Multi-version support** for PostgreSQL 13, 14, 15, 16, 17, and 18
- **Single database or full cluster backup** via `pg_dump` or `pg_dumpall`
- **AWS S3 and any S3-compatible storage** (Cloudflare R2, MinIO, Backblaze B2, etc.)
- **Configurable cron schedule** so backups run exactly when you want
- **Gzip compression** to keep storage costs low
- **Lifecycle hooks** for pre- and post-backup scripting
- **Timestamped structured logs** for easy monitoring and debugging

---

## Quick Start

```bash
docker run -d \
  -e POSTGRES_HOST=db \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_DB=mydb \
  -e S3_BUCKET=my-backups \
  -e AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  -e AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \
  -e AWS_DEFAULT_REGION=us-east-1 \
  ghcr.io/your-org/postgres-s3-backup:18
```

The container connects to the database at `POSTGRES_HOST`, dumps `mydb`, and uploads a compressed file to `s3://my-backups/backups/` every night at 02:00 UTC by default.

---

## Environment Variables

| Variable | Default | Required | Description |
|---|---|---|---|
| `POSTGRES_HOST` | | **Yes** | PostgreSQL host |
| `POSTGRES_PORT` | `5432` | No | PostgreSQL port |
| `POSTGRES_USER` | | **Yes** | PostgreSQL username |
| `POSTGRES_PASSWORD` | | **Yes** | PostgreSQL password |
| `POSTGRES_DB` | | **One of*** | Database name for single-db backup (`pg_dump`) |
| `POSTGRES_BACKUP_ALL` | `false` | **One of*** | Set to `true` to dump all databases (`pg_dumpall`) |
| `POSTGRES_EXTRA_OPTS` | | No | Extra flags passed to `pg_dump` (e.g. `--exclude-table-data=logs`) |
| `S3_BUCKET` | | **Yes** | S3 bucket name |
| `S3_PREFIX` | `backups` | No | Key prefix inside the bucket |
| `AWS_ACCESS_KEY_ID` | | **Yes** | AWS or S3-compatible access key |
| `AWS_SECRET_ACCESS_KEY` | | **Yes** | AWS or S3-compatible secret key |
| `AWS_DEFAULT_REGION` | | **Yes** | AWS region (any string works for non-AWS providers) |
| `AWS_ENDPOINT_URL` | | No | Custom endpoint URL for S3-compatible storage |
| `BACKUP_CRON_SCHEDULE` | `0 2 * * *` | No | Cron expression controlling when backups run |

> **\*Exactly one of `POSTGRES_DB` or `POSTGRES_BACKUP_ALL=true` must be set.** Setting both or neither will cause the backup to fail with an error.

---

## Docker Compose Sidecar Example

Add the `backup` service next to your existing `db` service. It inherits the same network so it can reach PostgreSQL by service name.

```yaml
version: '3.8'

services:
  db:
    image: postgres:18-alpine
    environment:
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: mydb
    volumes:
      - pgdata:/var/lib/postgresql/data

  backup:
    image: ghcr.io/your-org/postgres-s3-backup:18
    depends_on:
      - db
    environment:
      POSTGRES_HOST: db
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: secret
      POSTGRES_DB: mydb
      S3_BUCKET: my-backups
      AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
      AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
      AWS_DEFAULT_REGION: us-east-1
      BACKUP_CRON_SCHEDULE: "0 3 * * *"
    volumes:
      - ./hooks:/hooks

volumes:
  pgdata:
```

Store your real credentials in a `.env` file alongside the compose file and Docker will substitute them automatically.

---

## S3-Compatible Storage

Set `AWS_ENDPOINT_URL` to point the AWS CLI client at any S3-compatible provider instead of Amazon.

**Cloudflare R2**

```
AWS_ENDPOINT_URL=https://<account-id>.r2.cloudflarestorage.com
AWS_DEFAULT_REGION=auto
```

**MinIO**

```
AWS_ENDPOINT_URL=http://minio:9000
AWS_DEFAULT_REGION=us-east-1
```

The `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` variables map to whatever credential scheme your provider uses. The actual key strings just need to match what the provider expects.

---

## Lifecycle Hooks

Mount a local `hooks/` directory to `/hooks` inside the container and the backup script will source any executable scripts it finds there before and after each backup run.

| Script | When it runs |
|---|---|
| `/hooks/pre-backup.sh` | Before the dump starts |
| `/hooks/post-backup.sh` | After a successful upload |

Scripts must be executable before the container starts:

```bash
chmod +x hooks/pre-backup.sh hooks/post-backup.sh
```

Mount them with:

```bash
-v ./hooks:/hooks
```

**Example: Discord webhook notification on successful backup**

```bash
#!/bin/bash
curl -s -X POST "$DISCORD_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "{\"content\": \"✅ PostgreSQL backup completed at $(date '+%Y-%m-%d %H:%M:%S')\"}"
```

Save that as `hooks/post-backup.sh`, make it executable, and set `DISCORD_WEBHOOK_URL` in your environment. You'll get a message in your channel every time a backup finishes cleanly.

---

## Multi-Version Support

Each image tag corresponds to a specific PostgreSQL major version:

| Tag | PostgreSQL version |
|---|---|
| `:13` | PostgreSQL 13 |
| `:14` | PostgreSQL 14 |
| `:15` | PostgreSQL 15 |
| `:16` | PostgreSQL 16 |
| `:17` | PostgreSQL 17 |
| `:18` | PostgreSQL 18 |
| `:latest` | PostgreSQL 18 |

**Why does this matter?** Using the wrong `pg_dump` version against your PostgreSQL server produces errors. Each image bundles the exact `pg_dump` version for that major release, so the client and server always speak the same protocol. Match the image tag to the major version of your PostgreSQL server and you'll never hit a version mismatch.

---

## Restoring a Backup

Backups land in your bucket as compressed files. Download one and pipe it through the appropriate restore command.

**Single database backup** (`.dump.gz`, custom format)

```bash
gunzip -c backup.dump.gz | pg_restore -h <host> -U <user> -d <dbname>
```

**Full cluster backup** (`.sql.gz`, plain SQL)

```bash
gunzip -c all_backup.sql.gz | psql -h <host> -U <user> -f -
```

For single-db restores, add `--clean` to `pg_restore` if you want to drop and recreate objects before restoring. For cluster restores, connect to the `postgres` database or a superuser role that has access across all databases.

---

## License

MIT. See [LICENSE](LICENSE) for the full text.
