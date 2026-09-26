# Restore and verification

Recovery is a workflow, not just an extraction command. Inspect a backup,
verify its integrity, restore to a deliberate target, then test the recovered
application or data.

## Find a version

```bash
backfort.sh -c /etc/backfort/config.yaml list --job web
backfort.sh -c /etc/backfort/config.yaml status --job web
backfort.sh -c /etc/backfort/config.yaml restore --pick --job web --to /srv/recovery/web
```

`restore --pick` presents available versions and lets an operator choose one
interactively. Use it from a terminal; it intentionally refuses to guess when
standard input is not interactive.

## Verify before an incident

Run a quick check after every important backup and schedule deeper checks for
critical jobs:

```bash
# Check the latest or selected version's manifest, completion marker and hashes.
backfort.sh -c /etc/backfort/config.yaml verify web-20260926T020000Z

# Request full verification when the job/configuration supports it.
backfort.sh -c /etc/backfort/config.yaml verify web-20260926T020000Z --full

# Verify a remote copy, rather than the local primary destination.
backfort.sh -c /etc/backfort/config.yaml verify web-20260926T020000Z --from r2-archive
```

Verification detects a missing completion marker, manifest mismatch, corrupt
archive, signature failure where configured, and unavailable storage. A version
without `.complete` is incomplete and must never be selected for recovery.

## Restore a normal file job

```bash
# Restore using the paths recorded by the backup job.
backfort.sh -c /etc/backfort/config.yaml restore web-20260926T020000Z --to /srv/recovery/web

# Restore an off-site copy.
backfort.sh -c /etc/backfort/config.yaml restore web-20260926T020000Z --from s3-primary --to /srv/recovery/web
```

Restore targets are intentionally controlled by the job configuration. Test on
a disposable host or an explicit recovery directory first. Never overwrite a
live deployment until the recovered files, ownership and application start-up
have been checked.

## Restore a Compose project

First restore the Compose version. Its contents are organised in familiar
directories:

```text
compose/       project files selected by source.files
bind-mounts/   archived bind-mounted host paths
volumes/       named-volume archives
databases/     logical database dumps
```

To load a named-volume archive, stop the workload and use a temporary helper
container suitable for your platform. This illustrative command restores an
archive to `postgres_data`; adjust the archive path and inspect it first:

```bash
docker compose -f /recovery/crm/compose/compose.yaml down
docker volume create postgres_data
docker run --rm \
  -v postgres_data:/target \
  -v /recovery/crm/volumes/postgres_data:/backup:ro \
  alpine:3.20 sh -c 'cd /target && tar xf /backup/data.tar'
```

Use a logical dump for the database itself. Examples:

```bash
# PostgreSQL custom format
docker compose exec -T db createdb -U postgres crm
docker compose exec -T db pg_restore -U postgres -d crm --clean --if-exists \
  < /recovery/crm/databases/crm-postgres/crm.dump

# PostgreSQL plain SQL
docker compose exec -T db psql -U postgres -d crm \
  < /recovery/crm/databases/crm-postgres/crm.sql

# MySQL or MariaDB
docker compose exec -T db mysql -u root -p crm \
  < /recovery/crm/databases/crm-mysql/crm.sql
```

For MS SQL Server and Oracle, import the retained database export using the
vendor-supported tool and a target instance with a compatible version. Review
the dump type, engine version and user privileges before running it.

## A recovery drill

At least quarterly, choose a recent off-site backup and prove that it works:

1. Provision an isolated host or test environment.
2. Run `verify --full` against the remote copy.
3. Restore files and data without touching production.
4. Import a database dump and start the service.
5. Perform a real application-level check: login, representative report,
   object count, or another meaningful operation.
6. Record the backup ID, duration and gaps found.

The best backup is a backup with a successful recovery drill.
