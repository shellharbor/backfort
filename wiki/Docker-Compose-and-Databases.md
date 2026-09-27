# Docker Compose and databases

Backfort can make a recoverable snapshot of a Docker Compose project: selected
project files, named volumes and bind mounts. Database containers also receive
a supported database dump; for PostgreSQL, MySQL and MariaDB this is a logical
export, which is preferable to copying a live database volume alone.

## A full Compose job

```yaml
jobs:
  - name: crm-production
    source:
      type: docker_compose
      project_dir: /srv/crm
      files:
        - compose.yaml
        - .env
      volumes:
        - uploads
      volume_helper_image: registry.example/backfort-volume-helper@sha256:REPLACE_WITH_DIGEST
      bind_mounts:
        - name: uploads
          path: data/uploads
      databases:
        - name: crm-postgres
          service: db
          engine: postgres
          user: crm_backup
          password_env: BACKFORT_CRM_PG_PASSWORD
          databases: [crm]
          include_globals: true
          format: custom
    destinations: [local-archive, r2-archive]
```

`project_dir` must be an absolute path. `files` and `bind_mounts.path` are resolved from
that directory. List only the application files and persistent data required
to bring the project back; secrets should come from a secret manager or a
protected host configuration, not a backup configuration committed to Git.

Backfort writes the Compose payload below `compose/`, named volumes below
`volumes/`, bind mounts below `bind-mounts/`, and logical database dumps below
`databases/` in each backup version.

## Named-volume helper image

Reading a Docker named volume runs a short-lived helper container. Pin and
pre-pull a trusted helper image on production hosts where image downloads are
restricted:

```yaml
source:
  volumes: [uploads]
  volume_helper_image: registry.example/backfort-volume-helper@sha256:REPLACE_WITH_DIGEST
```

The Docker daemon must be available to the account running Backfort, and the
helper needs a writable target mount. Backfort gives the helper no network, a
read-only root filesystem, a read-only source volume, and no Linux
capabilities except `DAC_READ_SEARCH`. That single capability lets a trusted
`tar` helper traverse application-owned `0700` volume directories without
granting write, network, or general privilege. Pin an image that includes
`tar` and runs the helper command as root. Run `backfort.sh doctor` after
setting this up: it checks Docker and reports unavailable prerequisites before
the backup window.

## Database dumps

| Engine | Output | Notes |
| --- | --- | --- |
| PostgreSQL | `.dump` by default | `pg_dump` custom format; restore with `pg_restore`. |
| PostgreSQL with `format: sql` | `.sql` | Plain SQL; restore with `psql`. |
| MySQL | `.sql` | Created with `mysqldump`. |
| MariaDB | `.sql` | Created with `mariadb-dump`/compatible client. |
| Microsoft SQL Server | database backup/dump payload | Uses the configured SQL Server tooling in the container. |
| Oracle | Oracle export payload | Requires Oracle export tooling in the container. |

For a Postgres dump that can be read or restored without `pg_restore`, select
plain SQL explicitly:

```yaml
databases:
  - name: app-postgres
    service: db
    engine: postgres
    user: backup
    password_env: BACKFORT_PG_PASSWORD
    databases: [app]
    format: sql
```

For an MS SQL Server or Oracle container, define the service and engine in the
same `databases` list. Keep credentials in the named environment variable:

```yaml
databases:
  - name: sales-mssql
    service: sqlserver
    engine: mssql
    user: sa
    password_env: BACKFORT_MSSQL_PASSWORD
    databases: [Sales]
    backup_directory: /var/opt/mssql/backups
  - name: sales-oracle
    service: oracle
    engine: oracle
    user: system
    password_env: BACKFORT_ORACLE_PASSWORD
    connect: ORCLPDB1
    directory: BACKFORT_DIR
    path: /opt/oracle/backfort
```

Do not put a password literal in the YAML. Arrange for the environment variable
to be set by the scheduler, systemd credential mechanism, or a secret manager.
`doctor` verifies that every configured Compose database password variable is
non-empty before the backup window. During a multi-job `run`, an unset variable
fails only that job at `stage=preflight`, records a failed Prometheus result
when metrics are enabled, sends the normal failure event, and lets independent
jobs continue. No dump container is started for that failed job.

## Recommended recovery sequence

1. Restore the application files, bind mounts and named-volume archives.
2. Start only dependencies needed for the target database, or create an empty
   database service.
3. Use `restore-compose` to stage the verified version and print its recovery
   inventory. After reviewing and preparing an isolated target project, it can
   explicitly import supported logical dumps.
4. Start the rest of the Compose project and verify the application.

A database dump is the authoritative database recovery artifact. The raw volume
is still valuable for incident investigation and for services that do not offer
a logical dump, but restoring a live database directory across engine versions
is risky.

## Compose restore assistant

Stage a completed Compose version into a new or empty directory and receive a
machine-readable recovery inventory:

```bash
backfort.sh -c /etc/backfort/config.yaml \
  restore-compose latest --job crm-production --to /srv/recovery/crm
```

The command performs normal signature/checksum verification first. It never
copies recovered files to a deployment, creates a volume, starts a container,
or imports a database merely because the backup contains one.

Once a **different, prepared target project** has reviewed Compose files and
secrets and has its database services running, allow one logical import with
both explicit switches:

```bash
backfort.sh -c /etc/backfort/config.yaml \
  restore-compose latest --job crm-production --to /srv/recovery/crm-import \
  --project-dir /srv/crm-recovery --apply --confirm
```

The assistant runs `pg_restore` for custom PostgreSQL dumps, `psql` for plain
PostgreSQL SQL, and `mysql`/`mariadb` for the matching SQL dumps. It keeps
passwords in the configured environment variables and passes them only as
container environment variables. It refuses an apply that includes MS SQL or
Oracle; use the vendor recovery procedure for those native artifacts.

See [Restore and Verification](Restore-and-Verification) for concrete import
commands, [Quick Backups](Quick-Backups) for a one-command Compose snapshot,
and [Compose Migration](Compose-Migration) for a staged server move.
