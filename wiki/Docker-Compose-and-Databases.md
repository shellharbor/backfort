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
helper needs a writable target mount. Run `backfort.sh doctor` after setting this
up: it checks Docker and reports unavailable prerequisites before the backup
window.

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

## Recommended recovery sequence

1. Restore the application files, bind mounts and named-volume archives.
2. Start only dependencies needed for the target database, or create an empty
   database service.
3. Import the logical SQL dump into a fresh database.
4. Start the rest of the Compose project and verify the application.

A database dump is the authoritative database recovery artifact. The raw volume
is still valuable for incident investigation and for services that do not offer
a logical dump, but restoring a live database directory across engine versions
is risky.

See [Restore and Verification](Restore-and-Verification) for concrete import
commands, and [Quick Backups](Quick-Backups) for a one-command Compose snapshot.
