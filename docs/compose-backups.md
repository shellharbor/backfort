# Docker Compose backup contract

Docker Compose recovery is implemented in Backfort 1.2. This document defines
the safety boundary of that adapter and the operator responsibilities that
remain intentionally manual during a restore.

## Outcome

A completed backup of a Compose project must contain enough data to recover
the selected application data into a deliberately new recovery environment:

1. explicitly selected Compose files needed to identify services, images and
   named volumes;
2. archives of explicitly selected non-database named volumes;
3. logical, engine-aware database backups; and
4. the normal Backfort payload, metadata, checksum and final `.complete`
   marker at every destination.

An image export or a tar archive of a live database volume is not a database
backup. It is best-effort operational data and must never be treated as
application-consistent.

## Configuration direction

The adapter uses explicit source and database declarations. Backfort never
guesses a database engine from an image name.

```yaml
jobs:
  - name: crm-production
    source:
      type: docker_compose
      project_dir: /srv/crm
      files: [compose.yaml, compose.production.yaml]
      volumes: [uploads, documents]
      volume_helper_image: registry.example/backfort-volume-helper@sha256:REPLACE_WITH_DIGEST
      bind_mounts:
        - name: uploads
          path: data/uploads
      databases:
        - name: crm-postgres
          service: postgres
          engine: postgres
          user: backfort
          password_env: BACKFORT_PG_PASSWORD
          databases: [crm]
          include_globals: true
        - name: analytics-mysql
          service: mysql
          engine: mysql
          user: backfort
          password_env: BACKFORT_MYSQL_PASSWORD
          databases: [analytics]
```

This is valid 1.2 configuration after replacing placeholder values. `volumes`
contains logical Compose volume names, not host mount paths. Backfort resolves
them through `docker compose config` and archives them through a helper image
that must already exist locally; it will not pull images during a backup.

## Consistency rules

- PostgreSQL uses `pg_dump` in custom format for each configured database and
  a separate `pg_dumpall --globals-only` artifact when requested.
- MySQL and MariaDB use a logical dump with routines, events and triggers.
  `--single-transaction` is documented as unsuitable for non-transactional
  tables.
- Named volumes that do not contain a database are archived through a
  temporary helper container with network disabled, a read-only root filesystem
  and a read-only source-volume mount. They are best-effort unless a storage
  snapshot integration is added later.
- Backfort 1.2 does not stop services. Any future stop operation must record
  exactly which services it stopped and restart those services in an
  unconditional cleanup path.
- Bind mounts and `.env` files are never copied implicitly. They require an
  explicit allow-list because they often contain host data or secrets.

## Credentials

Configuration stores environment-variable names, never secrets. A dedicated,
least-privileged database account is recommended. Backfort passes passwords by
an engine-specific environment variable to `docker compose exec`; it does not
place a password in command-line arguments, log output or bundle metadata.

MS SQL uses `sqlcmd` for a `COPY_ONLY, CHECKSUM` native `.bak`, then copies that
file from the target container and removes the temporary container file. Oracle
uses `expdp` in `FULL=Y` mode, copies the produced `.dmp`, then removes its dump
and log files. Those adapters require compatible vendor tools and privileges in
the selected container; this is checked at dump time rather than guessed from
the image name.

### MS SQL and Oracle declarations

MS SQL needs a writable directory inside the database container. It is used
only for the short-lived native backup file; Backfort copies the file out and
attempts to remove it even after a copy failure.

```yaml
- name: reporting-mssql
  service: mssql
  engine: mssql
  user: backfort
  password_env: BACKFORT_MSSQL_PASSWORD
  databases: [reporting]
  backup_directory: /var/opt/mssql/backups
```

Oracle Data Pump needs both the Oracle directory object and the filesystem path
to which that object resolves in the container. The `connect` value is the PDB
or service name used by `expdp`.

```yaml
- name: billing-oracle
  service: oracle
  engine: oracle
  user: backfort
  password_env: BACKFORT_ORACLE_PASSWORD
  connect: FREEPDB1
  directory: DATA_PUMP_DIR
  path: /opt/oracle/admin/FREE/dpdump
```

Use a dedicated account with only the export or backup privileges it needs.
`FULL=Y` Oracle exports and native MS SQL backups can be sizeable, so reserve
space both in Backfort's temporary directory and the configured container path.

## Remote copies

Backfort uses `rclone` destinations for remote transport. A destination
references an already configured rclone remote and a constrained relative
path, for example:

```yaml
destinations:
  - name: s3-offsite
    type: rclone
    remote: company-s3
    path: backups-bucket/backfort/crm-production
```

AWS S3, DigitalOcean Spaces, Vultr Object Storage, and Cloudflare R2 are all
configured as rclone S3-compatible remotes; their bucket is normally the first
component of `path`. Backfort publishes them with the same payload → metadata
→ checksum → `.complete` order as every other rclone destination.

The adapter uploads payload, metadata and checksum before `.complete`; it uses
copy operations, never `sync`, so a backup run cannot infer permission to
delete unrelated remote data. `min_copies` is available now; specifically
required destinations will be added with the Compose adapter.

## Restore sequence

1. Run `verify --full`, then restore into an empty directory.
2. Inspect the recovered `compose/` files and use a new Compose project name
   and isolated network/ports for the drill.
3. Create new, empty named volumes and extract each selected
   `volumes/<name>/data.tar` into its matching recovery volume with the same
   helper image.
4. Restore bind-mount contents only into an isolated recovery path.
5. For PostgreSQL, MySQL, and MariaDB, optionally use the explicit Compose
   restore assistant after the target database services are running:

   ```bash
   backfort.sh -c /etc/backfort/config.yaml \
     restore-compose latest --job crm-production --to /srv/recovery/crm-import \
     --project-dir /srv/crm-recovery --apply --confirm
   ```

   It verifies and stages the archive first, checks the target Compose project
   and running database services, then invokes the matching client inside each
   database container. It never copies recovered project files, unpacks
   volumes, or starts services. PostgreSQL global roles, MS SQL Server, and
   Oracle remain manual vendor procedures; an apply is rejected before any
   import when its job includes MS SQL or Oracle.
6. Start the recovery project and validate the application.

Backfort intentionally does not automate project deployment, volume restoration,
or service startup. A restore drill can orchestrate those disposable
infrastructure steps; production recovery remains an explicit, reviewable
operation.
