# Move a Docker Compose project to a new server

This runbook moves a Compose project to a prepared, empty target host with
Backfort. It is deliberately staged: Backfort creates and verifies a portable
backup, while the operator chooses the new volume names, database target and
cutover moment. It does not make an SSH connection to another server, replace a
live volume, or run `docker compose up`. Logical database import is available
only through the separately confirmed `restore-compose --apply --confirm`
step below.

Use this for a one-time move or rehearse the same procedure before a planned
host replacement. For a permanent scheduled job, start from
[`examples/compose-migration.yaml`](https://github.com/shellharbor/backfort/blob/main/examples/compose-migration.yaml).

## What moves

`quick-compose` includes only what you name:

| Item | Include with | Recovery result |
| --- | --- | --- |
| Compose and environment files | `--file FILE` | `compose/` in the staged restore |
| Named non-database volume | `--volume NAME` plus helper image | `volumes/NAME/data.tar` |
| Bind-mounted path | `--bind NAME:RELATIVE_PATH` | `bind-mounts/NAME/` |
| PostgreSQL, MySQL, MariaDB database | `--db ...` | logical SQL dump below `databases/NAME/` |

It does **not** include container images, ephemeral writable layers, unnamed
volumes, every file under the project, or a live database volume. Pull images
on the target through the normal deployment process. Use a logical database
dump rather than a raw database data-directory copy.

## 1. Prepare the migration

Before the maintenance window:

1. Choose a transfer destination reachable from both hosts, for example an
   rclone Cloudflare R2, AWS S3, DigitalOcean Spaces or Vultr Object Storage
   remote.
2. Install Backfort, Docker Compose, rclone and the required database client on
   the source; install Backfort, Docker Compose, rclone and a trusted volume
   helper image on the target.
3. Configure the same rclone remote name on both hosts, using credentials with
   only the required bucket/path access.
4. List every required Compose file, `.env` file, bind mount, named volume and
   database. Do not include the live volume of a database for which a logical
   dump is available.
5. Schedule application quiescence or a maintenance window. A logical database
   dump is consistent for its engine, but application files and uploads can
   otherwise change during a running snapshot.

## 2. Snapshot the source server

Set the database password in a secret manager or protected scheduler
environment. The command uses only the *name* of the variable and never writes
its value to the recovery configuration.

```bash
# First, inspect the exact plan without writing data.
sudo backfort.sh --dry-run quick-compose /srv/crm \
  --name crm-server-move \
  --file compose.yaml --file .env \
  --to rclone:cloudflare-r2:backfort-migrations/crm \
  --volume uploads \
  --volume-helper-image registry.example/backfort-volume-helper@sha256:REPLACE_WITH_DIGEST \
  --bind uploads:data/uploads \
  --db crm-postgres:postgres:postgres:backfort:BACKFORT_PG_PASSWORD:crm

# After reviewing the plan, run the same command without --dry-run.
```

Add a second `--to /var/backups/backfort-migration` and set `--min-copies 2`
when the migration must have both a local staging copy and a transfer copy.
After a real run, record the logged recovery-config path, normally:

```text
/root/.local/state/backfort/quick-compose/crm-server-move.yaml
```

Copy that non-secret YAML file to the target through an approved administrative
channel. It contains source paths and destination references, so restrict its
permissions even though it contains no credential values.

```bash
scp /root/.local/state/backfort/quick-compose/crm-server-move.yaml \
  root@new-server:/root/backfort-migration/crm-server-move.yaml
```

## 3. Verify and stage the backup on the target

On the target, create the parent recovery directory, ensure the rclone remote
is ready, then inspect the available copy. The generated configuration has one
rclone destination in the example above, so `latest` resolves that remote copy.

```bash
sudo install -d -m 0700 /root/backfort-migration /srv/recovery
sudo /opt/backfort/backfort.sh \
  -c /root/backfort-migration/crm-server-move.yaml \
  list --job crm-server-move
sudo /opt/backfort/backfort.sh \
  -c /root/backfort-migration/crm-server-move.yaml \
  verify latest --job crm-server-move --full
sudo /opt/backfort/backfort.sh \
  -c /root/backfort-migration/crm-server-move.yaml \
  restore-compose latest --job crm-server-move --to /srv/recovery/crm
```

The restore target must be new or empty. Inspect it before applying anything:

```text
/srv/recovery/crm/
├── compose/
├── volumes/uploads/data.tar
├── bind-mounts/uploads/
└── databases/crm-postgres/crm.sql
```

If full verification or restore fails, stop there. Keep the source production
service running, fix the storage/key/tooling issue, and create a new verified
backup rather than proceeding from a partial one.

## 4. Recreate the target project and data

Copy the recovered Compose files and bind mount into the intended target
project directory. Review `.env`, image tags, exposed ports, host paths, and
secrets for the new host before creating containers.

```bash
sudo install -d -m 0750 /srv/crm /srv/crm/data/uploads
sudo cp -a /srv/recovery/crm/compose/. /srv/crm/
sudo cp -a /srv/recovery/crm/bind-mounts/uploads/. /srv/crm/data/uploads/
cd /srv/crm
sudo docker compose create
sudo docker volume ls
```

`docker compose create` creates the target project resources without starting
the services. Identify the actual named volume it created for the logical
`uploads` volume, then unpack the archived volume into that **new, stopped**
volume. Here it is named `crm_uploads`; use the name from the target host, not
an assumed source name.

```bash
sudo docker run --rm --network none --read-only --cap-drop ALL \
  -v crm_uploads:/target \
  -v /srv/recovery/crm/volumes/uploads:/backup:ro \
  registry.example/backfort-volume-helper@sha256:REPLACE_WITH_DIGEST \
  tar --extract --file /backup/data.tar --directory /target
```

Start only the database service and wait for its normal readiness condition.
Then use the assistant to make a fresh, verified staging extraction and import
the logical dump into the intended fresh database. `quick-compose` produces
plain PostgreSQL SQL, so this run invokes `psql` with `ON_ERROR_STOP` inside the
target container:

```bash
cd /srv/crm
sudo docker compose up -d postgres
# Wait until the database reports ready using the image's normal health check.
# Create `crm` first only when the image/init configuration did not already do so:
# sudo docker compose exec -T postgres createdb -U postgres crm
sudo /opt/backfort/backfort.sh \
  -c /root/backfort-migration/crm-server-move.yaml \
  restore-compose latest --job crm-server-move --to /srv/recovery/crm-import \
  --project-dir /srv/crm --apply --confirm
```

The assistant supports PostgreSQL, MySQL, and MariaDB. It deliberately does
not recreate volumes, copy Compose files, start application services, or apply
PostgreSQL `globals.sql`. For MS SQL Server or Oracle, use a regular YAML
Compose job and the vendor-native recovery procedure; an `--apply` run refuses
before importing anything when either engine is configured.

## 5. Validate, cut over, and retain rollback

1. Start the remaining services with `docker compose up -d`.
2. Verify application health, authentication, an upload/download or other
   meaningful persistent-data workflow, and database record counts.
3. Keep the source system available until the target has passed the agreed
   acceptance checks and a backup of the target itself exists.
4. Pin the source migration backup before cutover if it must outlive ordinary
   retention, and remove the pin only after the rollback window closes.

```bash
sudo /opt/backfort/backfort.sh \
  -c /root/backfort-migration/crm-server-move.yaml \
  pin BACKUP_ID --reason 'source rollback point during CRM migration'
```

Do not delete the source server, transfer copy, or verified recovery artifacts
until the migration is formally accepted and the new host has its own tested
backup policy.
