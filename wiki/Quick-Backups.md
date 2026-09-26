# Quick Backups

Quick commands are for an immediate, fully formed backup before a durable YAML
plan exists. They still use checksum generation, atomic publication, local or
rclone destinations, `min_copies`, and a saved recovery configuration.

Use a normal configuration for scheduled production jobs. Quick commands are
especially useful before a migration, a manual upgrade, or an urgent change.

## Quick files and directories

```bash
sudo backfort.sh quick /etc /srv/www/site \
  --name site-before-upgrade \
  --to /var/backups/backfort \
  --to rclone:cloudflare-r2:production-backups/backfort/site \
  --min-copies 2 \
  --exclude '*.log' \
  --exclude '*/cache/*'
```

`quick` accepts one or more absolute paths. Options may appear before or after
paths. It uses gzip compression, no encryption, and the standard retention
defaults (`keep_last: 3`) in the generated recovery config.

| Option | Meaning |
| --- | --- |
| `--name NAME` | Stable job name used in backup IDs and the saved YAML file. |
| `--to PATH` | Local absolute destination path; repeat for more copies. |
| `--to rclone:REMOTE:PATH` | rclone destination, such as an S3 bucket path. |
| `--min-copies N` | Required number of successful independent copies. |
| `--exclude PATTERN` | GNU tar exclude pattern; repeat as needed. |
| `--follow-symlinks` | Archive target data rather than the symlink itself. |
| `--state-directory PATH` | Choose where the recovery config and runtime state live. |
| `-n` / `--dry-run` | Validate and plan without writes. |

Start safely:

```bash
sudo backfort.sh --dry-run quick /srv/myapp \
  --to /var/backups/backfort --name myapp-safety-copy
```

## Recovery config created by `quick`

After a real run, Backfort logs a file like:

```text
event=quick-config-saved file=/root/.local/state/backfort/quick/site-before-upgrade.yaml
```

This file contains paths and destination references, never secret values. Keep
it with the recovery documentation and use it for ordinary operations:

```bash
sudo backfort.sh -c /root/.local/state/backfort/quick/site-before-upgrade.yaml \
  list --job site-before-upgrade

sudo backfort.sh -c /root/.local/state/backfort/quick/site-before-upgrade.yaml \
  restore latest --job site-before-upgrade --to /srv/recovery/site
```

## Quick Docker Compose backup

`quick-compose` creates an explicit Compose project backup. It does not guess
volumes, bind mounts, or databases; each must be selected on the command line.

```bash
# Ensure BACKFORT_PG_PASSWORD is exported by a secret manager or protected shell.

sudo backfort.sh quick-compose /srv/crm \
  --name crm-before-migration \
  --file compose.yaml \
  --to /var/backups/backfort \
  --to rclone:aws-s3:production-backups/backfort/crm \
  --min-copies 2 \
  --volume uploads \
  --volume-helper-image registry.example/backfort-volume-helper@sha256:REPLACE_WITH_DIGEST \
  --bind uploads:data/uploads \
  --db crm-postgres:postgres:postgres:backfort:BACKFORT_PG_PASSWORD:crm
```

The `--db` format is:

```text
NAME:SERVICE:ENGINE:USER:PASSWORD_ENV:DB1,DB2
```

Quick database dumps support `postgres`, `mysql`, and `mariadb`. PostgreSQL
quick dumps are plain `.sql`, so a staged restore uses `psql`; MySQL and
MariaDB also generate `.sql`. Use the regular YAML Compose job for MS SQL and
Oracle because their reliable adapters produce native `.bak` and `.dmp`
artifacts, not a pretend SQL dump.

The Compose recovery config is saved below
`$XDG_STATE_HOME/backfort/quick-compose/` or
`$HOME/.local/state/backfort/quick-compose/`.

Read [Docker Compose and Databases](Docker-Compose-and-Databases) before using
a database volume or restoring a database dump.
