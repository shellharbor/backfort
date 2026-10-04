# Backfort

![Backfort shell bash backup script](https://i.postimg.cc/15hRLgv0/backfort-hero-dark-terminal-alt.jpg)

> **Your last line of data defense.** Back up deliberately. Restore with
> confidence.

Backfort is a recovery-first backup tool for Linux servers. It creates an
explicit, verified backup and exits—no daemon to babysit, no hidden discovery
of files or databases, and no risky in-place restore switch.

[![CI](https://github.com/shellharbor/backfort/actions/workflows/ci.yml/badge.svg)](https://github.com/shellharbor/backfort/actions/workflows/ci.yml)
[![Kubernetes](https://github.com/shellharbor/backfort/actions/workflows/kubernetes.yml/badge.svg)](https://github.com/shellharbor/backfort/actions/workflows/kubernetes.yml)
[![Documentation](https://github.com/shellharbor/backfort/actions/workflows/documentation.yml/badge.svg)](https://github.com/shellharbor/backfort/actions/workflows/documentation.yml)
[![CodeQL](https://github.com/shellharbor/backfort/actions/workflows/codeql.yml/badge.svg)](https://github.com/shellharbor/backfort/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/shellharbor/backfort/badge)](https://scorecard.dev/viewer/?uri=github.com/shellharbor/backfort)
[![GitHub release](https://img.shields.io/github/v/release/shellharbor/backfort)](https://github.com/shellharbor/backfort/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash 4.3+](https://img.shields.io/badge/bash-4.3%2B-4EAA25?logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![ShellCheck](https://img.shields.io/badge/lint-ShellCheck-4EAA25?logo=gnubash&logoColor=white)](https://www.shellcheck.net/)
[![GitHub issues](https://img.shields.io/github/issues/shellharbor/backfort)](https://github.com/shellharbor/backfort/issues)
[![GitHub stars](https://img.shields.io/github/stars/shellharbor/backfort?style=flat)](https://github.com/shellharbor/backfort/stargazers)

**[Get started](#first-backup--durable-setup)** ·
**[Run in Docker](#run-backfort-in-docker)** ·
**[Run in Kubernetes](#run-backfort-in-kubernetes)** ·
**[Examples](examples/README.md)** ·
**[Compose migration](wiki/Compose-Migration.md)** ·
**[Recovery guide](wiki/Restore-and-Verification.md)** ·
**[Security policy](SECURITY.md)**

Canonical repository: [github.com/shellharbor/backfort](https://github.com/shellharbor/backfort)

## Pick your path

| I need to… | Start here | What Backfort gives you |
| --- | --- | --- |
| Protect files and directories on a schedule | [First backup](#first-backup--durable-setup) | A strict YAML job for cron or a systemd timer. |
| Take a fast snapshot before a risky change | [Quick file backup](#quick-file-backup) | A one-command backup plus a reusable non-secret recovery config. |
| Run Backfort as a containerized job | [Run in Docker](#run-backfort-in-docker) | The same YAML plan and recovery format, with explicit persistent mounts. |
| Protect files on Kubernetes PVCs | [Run in Kubernetes](#run-backfort-in-kubernetes) | Helm Job/CronJob deployment with explicit read-only sources, durable state and isolated recovery. |
| Back up a Docker Compose stack | [Docker Compose sources](#docker-compose-sources) | Explicit project files, bind mounts, named volumes, and database dumps. |
| Move a Compose project to a new server | [Compose migration](wiki/Compose-Migration.md) | A staged runbook with rollback-minded cutover steps. |
| Restore a database to an isolated Compose project | [Compose restore assistant](#restore-safety) | Verified staging and an explicit PostgreSQL/MySQL/MariaDB import boundary. |
| Send copies off-site | [Rclone destinations](#rclone-destinations-and-copy-policy) | Local, S3-compatible, FTP, Dropbox, Yandex Disk, pCloud, and other rclone remotes. |

## Why recovery stays predictable

```text
explicit source → local bundle → checksum/signature → independent copies → .complete marker
                                                                          ↓
                                                       only then: list / verify / restore / prune
```

- **No guessing.** You name source paths, Compose files, volumes, bind mounts,
  databases, destinations, and exclusions.
- **No half-backup surprise.** Payload, metadata, and checksum arrive before
  the final `.complete` marker. Interrupted uploads are never valid restores.
- **No in-place roulette.** Restore always requires a new or empty directory;
  there is no `--force` overwrite path.
- **No secret values in YAML.** Configuration refers to environment-variable
  names, leaving passwords and keys with your secret manager or scheduler.

Backfort reads YAML, creates full backups, optionally compresses and encrypts
them, publishes each completed version atomically to one or more local or
rclone destinations, and exits. Scheduling belongs to cron, a systemd timer or a Kubernetes CronJob;
Backfort does not run a daemon.

Backfort 1.0.0 is the first stable release. It can archive explicit Compose
files, selected named volumes, explicit bind mounts and engine-aware database
dumps, then publish the resulting bundle through the same local and rclone
destinations as a file backup.

## Features

- One Bash 4.3+ executable and one YAML configuration
- Strict configuration validation with unknown-key detection
- Full-file and directory backups with GNU tar include roots and excludes
- Helm deployment for Kubernetes PVC-file backups, manual recovery Jobs and
  suspended-by-default backup/prune CronJobs
- Docker Compose project snapshots: manifests, selected named volumes and bind
  mounts
- Logical PostgreSQL, MySQL and MariaDB dumps; native MS SQL and Oracle export
  artifacts
- A staged Compose recovery assistant with an explicit, double-confirmed
  logical database import for PostgreSQL, MySQL and MariaDB
- `gzip`, `zstd`, or uncompressed archives
- Optional multi-recipient `age` or GPG encryption; GPG supports hardened
  symmetric passwords and asymmetric public-key recipients
- Optional detached Minisign payload signatures for untrusted storage
- Multiple independent local or rclone destinations
- Offsite copies through rclone, including AWS S3, DigitalOcean Spaces, Vultr
  Object Storage, Cloudflare R2, FTP/FTPS, Dropbox, Yandex Disk, pCloud and
  other rclone-supported remotes
- Explicit `min_copies` policy for a successful backup
- Durable local publication: data is synchronized before the final `.complete` marker
- Fast payload checksum verification plus full per-file SHA-256 verification
- Safe restore into a new or empty directory
- Opt-in interactive restore version selection for a manual terminal session
- GFS-style `keep_last`, daily, weekly, and monthly retention
- Per-destination pinned backups for migration and upgrade recovery points
- Safe opt-in `pre`/`post` lifecycle hooks for application quiescing and cleanup
- Event notifications through Telegram, ntfy, webhooks, or local sendmail
- Global `flock` for mutating commands
- Read-only dry-run mode and environment diagnostics
- Structured, journal-friendly log lines

## Requirements

- Linux
- Bash 4.3 or newer
- [Mike Farah yq](https://github.com/mikefarah/yq) v4
- GNU `tar`, `coreutils`, `findutils`, `util-linux`, and `gzip`
- Optional: `zstd`, `age`, GnuPG, Minisign, rclone, `curl`, `msmtp`, or `sendmail` when those features are enabled
- Docker Engine with the Compose v2 plugin for `docker_compose` sources
- A pre-pulled, locally trusted helper image containing `tar` for named-volume
  snapshots; Backfort never pulls container images itself

On Debian or Ubuntu, the base packages can be installed with:

```bash
sudo apt-get install bash coreutils findutils gzip tar util-linux
```

Install Mike Farah `yq` v4 using its official release or package. The Python
package with the same name is not compatible.

## Run Backfort in Docker

The container image is an additional distribution method, not a second backup
engine. It runs the same `backfort.sh`, accepts the same strict YAML, and
creates the same portable bundles as a native installation. Images are
published for `linux/amd64` and `linux/arm64` to GitHub Container Registry:

```bash
docker pull ghcr.io/shellharbor/backfort:1.2.0
docker run --rm ghcr.io/shellharbor/backfort:1.2.0 --version
```

For a durable setup, copy the sample Compose file and its matching config into
a root-owned deployment directory. The example is deliberately a one-shot
job: it defaults to `doctor` and does not restart itself.

```bash
sudo install -d -m 0700 /srv/backfort-container
sudo cp docker-compose.example.yml /srv/backfort-container/docker-compose.yml
sudo cp examples/docker-files-local.yaml /srv/backfort-container/config.yaml
sudoedit /srv/backfort-container/config.yaml

export BACKFORT_SOURCE_DIR=/srv/application
export BACKFORT_BACKUP_DIR=/srv/backups/backfort
cd /srv/backfort-container
docker compose run --rm backfort doctor
docker compose run --rm backfort --dry-run run
docker compose run --rm backfort run
```

The image starts as root on purpose: a full staged restore may need to recreate
numeric ownership, ACLs, extended attributes, or sparse files. A files-only
job can set a non-root `user:` in the sample when the source, backup and
restore mounts are already writable by that account; doing so intentionally
trades away owner-preserving recovery. The example has a read-only container
root filesystem, but its named state and work volumes and the destination bind
mount remain writable. `temp_directory` needs room for a complete working
bundle, not merely a small scratch file.

The `doctor` exit status is the container's honest readiness result. Backfort
is not a daemon, so it intentionally has no `HEALTHCHECK`, no port, and no
`restart: always`. Schedule `docker compose run --rm backfort run` from the
host with cron or a systemd timer; schedule `prune` separately.

For `docker_compose` jobs, mount the Docker socket and the target project
directory at its **same absolute host path** inside Backfort (for example,
`/srv/crm:/srv/crm:ro`). A Docker socket is host-root-equivalent even when
mounted read-only. Use it only for a trusted Compose job and never for a
normal files-only backup. The complete deployment, secret, recovery and
upgrade guidance is in [Docker deployment](wiki/Docker-Deployment.md).

Release tags are immutable exact versions such as `1.2.0`. Stable releases
also move `1.2`, `1`, and `latest`; pin an exact version or digest for a
repeatable run and retain the `backfort-state` volume during upgrades. Docker
Hub publication is optional and occurs only when the repository has both
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` release secrets; GHCR is the
canonical image registry.

## Run Backfort in Kubernetes

Already keeping your application files on PVCs? The [Helm chart](charts/backfort/README.md)
runs the same Backfort image as finite Jobs and CronJobs. It needs Helm 3,
Kubernetes 1.31+, and source PVCs in the release's namespace. Adapt the host ID,
claim names and storage capacity first:

```bash
cp examples/kubernetes/pvc-local.values.yaml values.yaml
helm lint charts/backfort --strict -f values.yaml
helm upgrade --install backfort ./charts/backfort -n application -f values.yaml
```

Both schedules start suspended. Run a manual `doctor`, dry-run, first backup,
full verification and recovery drill before enabling them. For example, a
deliberate backup can be launched from the suspended CronJob:

```bash
kubectl -n application create job backfort-backup-01 --from=cronjob/backfort-backup
kubectl -n application wait --for=condition=complete job/backfort-backup-01 --timeout=60m
kubectl -n application logs job/backfort-backup-01
```

Source PVCs are read-only; state and the shared lock persist on a separate PVC.
Copies go to another PVC or your existing rclone/S3/cloud destination. Manual
restore mounts only an explicitly isolated recovery PVC and still refuses a
nonempty target. The chart grants no Kubernetes API token, RBAC, Docker socket
or privileged host access. Full owner/ACL/xattr recovery uses the documented
root profile; a narrower non-root example is provided.

This is **PVC-file backup support, not whole-cluster backup**: no resource
discovery, CSI snapshot orchestration or native SQL dumps from database Pods.
A live database PVC is not a consistent backup. RWO/RWOP access modes and the
actual storage driver's permissions/locking need review before deployment.
The [Kubernetes runbook](wiki/Kubernetes-Deployment.md) covers those limits,
Secrets, scheduling, manual verification and safe restore, with
[ready-to-adapt values examples](examples/kubernetes/README.md).

## First backup — durable setup

### Need a quick safety copy first?

When you are about to deploy, upgrade, or perform manual maintenance, use the
`quick` command to protect only the paths you name. It creates an ordinary,
verifiable Backfort bundle and saves a non-secret recovery configuration below
the protected state directory:

```bash
sudo ./backfort.sh quick /etc/nginx /var/www \
  --name before-deploy \
  --to /var/backups/backfort
```

For a repeatable production policy, continue with the YAML setup below. See
[Quick Backups](wiki/Quick-Backups.md) for rclone, excludes, and Compose
variants.

### Install and create a durable configuration

Clone the canonical repository:

```bash
git clone https://github.com/shellharbor/backfort.git
cd backfort
```

Install the executable and create the runtime configuration:

```bash
sudo install -d -m 0755 /opt/backfort /etc/backfort
sudo install -m 0755 backfort.sh /opt/backfort/backfort.sh
sudo install -m 0640 config.example.yaml /etc/backfort/config.yaml
sudoedit /etc/backfort/config.yaml
```

Ready-to-adapt configurations are in [examples](examples/README.md). Start
with `doctor` and a dry run before creating the first production backup.

### Validate, create, and rehearse recovery

Check the complete configuration and environment without writing backup data:

```bash
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml doctor
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml --dry-run run
```

Create backups and inspect the result:

```bash
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml run
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml list
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml status
```

Verify and restore the newest backup for a job:

```bash
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml \
  verify latest --job important-files --full

sudo mkdir -m 0700 /srv/backfort-restore
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml \
  restore latest --job important-files --to /srv/backfort-restore
```

Backfort preserves absolute source locations below the restore directory. A
backup of `/etc/nginx` is restored to `/srv/backfort-restore/etc/nginx` in the
example above. It never writes directly back to the original source path.

### A calm operating rhythm

1. Run `doctor` whenever you change storage, credentials, encryption, hooks,
   or a Compose source.
2. Run `--dry-run` before a new or altered job.
3. Schedule `run` with cron or systemd; schedule `prune` separately.
4. Verify important copies with `verify --full` and perform a real staged
   recovery drill at least quarterly.
5. Pin pre-migration or pre-upgrade recovery points, then remove the pin when
   the rollback window closes.

### Common operator recipes

```bash
# 1) Make an explicit off-site copy before a deployment.
sudo ./backfort.sh quick /etc/nginx /var/www \
  --name pre-deploy \
  --to /var/backups/backfort \
  --to rclone:cloudflare-r2:backfort/web-01 \
  --min-copies 2

# 2) Capture a Compose project and its PostgreSQL logical dump before an upgrade.
# BACKFORT_CRM_PG_PASSWORD is supplied by your protected shell, scheduler, or secret manager.
sudo ./backfort.sh quick-compose /srv/crm \
  --name crm-before-upgrade \
  --file compose.yaml \
  --to rclone:cloudflare-r2:backfort/crm \
  --db crm-postgres:postgres:postgres:backfort:BACKFORT_CRM_PG_PASSWORD:crm

# 3) Keep a completed recovery point through normal retention.
sudo ./backfort.sh -c /etc/backfort/config.yaml \
  pin BACKUP_ID --reason 'rollback point before CRM upgrade'

# 4) Choose a completed version interactively and restore it safely.
sudo ./backfort.sh -c /etc/backfort/config.yaml \
  restore --pick --job important-files --to /srv/recovery/important-files
```

The two `quick` commands save a reusable recovery configuration under Backfort's
protected state directory. The `--db` option records only the **name** of the
password environment variable; it never serializes the password itself.

## Wiki, support, and security

The expanded operational guide—with configuration, S3/rclone, Compose,
database, recovery, retention, automation, and troubleshooting examples—is in
[the GitHub Wiki sources](wiki/Home.md).

- [Contributing](CONTRIBUTING.md) — development and test expectations
- [Security policy](SECURITY.md) — responsible vulnerability reporting
- [Code of Conduct](CODE_OF_CONDUCT.md) — collaboration expectations
- [Support](SUPPORT.md) — safe, useful bug-reporting context

## Configuration

The configuration has strict top-level keys:

```yaml
version: 1

settings:
  host_id: server-01
  state_directory: /var/lib/backfort
  temp_directory: /var/tmp/backfort
  lock_file: /run/backfort.lock
  min_free_mb: 512

metrics:
  prometheus:
    textfile_directory: /var/lib/node_exporter/textfile_collector

destinations:
  - name: local
    type: local
    path: /var/backups/backfort
  - name: s3-offsite
    type: rclone
    remote: company-s3
    path: backups-bucket/backfort/server-01

jobs:
  - name: important-files
    source:
      type: files
      paths: [/etc/nginx, /var/www]
      exclude: ["*.log", "*/cache/*"]
      follow_symlinks: false
    destinations: [local, s3-offsite]
    success: {min_copies: 2}
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    hooks:
      pre:
        path: /usr/local/lib/backfort/hooks/crm-maintenance
        args: [enable]
        timeout_seconds: 120
      post:
        path: /usr/local/lib/backfort/hooks/crm-maintenance
        args: [disable]
        timeout_seconds: 120
    retention:
      keep_last: 3
      keep_daily: 7
      keep_weekly: 4
      keep_monthly: 6
```

Names and `host_id` may contain letters, numbers, dots, underscores, and
hyphens. All filesystem paths must be absolute and must not contain `.` or
`..` components. Backfort rejects `/` as a
direct source or destination and rejects a destination, state directory, or
temporary directory located inside a configured source directory. This avoids
self-referential backups that grow while they are being created.

`host_id` is also the isolation boundary for automatic discovery. Give every
server that writes to the same local directory, bucket, or rclone path a stable
**different** value. `list`, `status`, `verify latest`, `restore latest`,
`restore --pick`, `watchdog`, `prune`, and date-range `delete` consider only
IDs made by the configured host. A fully specified backup ID remains available
for a deliberate cross-host recovery after the operator has reviewed it.

### Lifecycle hooks: safely quiesce an application

Some applications need a short, deliberate pause before their files are read:
for example, a filesystem may need `fsfreeze`, or an application may expose a
maintenance-mode command. A saved job can run an optional `pre` hook before
the archive pipeline and a `post` hook after it:

```yaml
hooks:
  pre:
    path: /usr/local/lib/backfort/hooks/crm-maintenance
    args: [enable]
  post:
    path: /usr/local/lib/backfort/hooks/crm-maintenance
    args: [disable]
```

The hook is an executable file with a literal argument array—not a command
string. Backfort never evaluates YAML as shell code. For a simple filesystem
freeze, the script can be intentionally boring and auditable:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

case "${BACKFORT_HOOK_PHASE}:${1:-}" in
  pre:freeze) fsfreeze --freeze /srv/crm-data ;;
  post:unfreeze) fsfreeze --unfreeze /srv/crm-data ;;
  *) printf 'unexpected Backfort hook invocation\n' >&2; exit 64 ;;
esac
```

Install the script under the account that runs Backfort—typically root—and do
not leave it writable by a service account:

```bash
sudo install -o root -g root -m 0750 crm-maintenance /usr/local/lib/backfort/hooks/crm-maintenance
```

`doctor` and `run` reject a hook that is missing, a symlink, owned by another
account, non-executable, or group/other-writable. `--dry-run run` prints the
planned hooks but never invokes them. Hooks run only for configured `run`
jobs; `quick`, `quick-compose`, restore, verify, list, prune, and doctor do
not execute them.

Backfort clears its environment before starting a hook. The hook receives only
a safe system `PATH`, `LANG=C`, and these non-secret variables:
`BACKFORT_HOOK_PHASE`, `BACKFORT_HOOK_JOB`, `BACKFORT_HOOK_BACKUP_ID`,
`BACKFORT_HOOK_CONFIG_FILE`, `BACKFORT_HOOK_SOURCE_TYPE`,
`BACKFORT_HOOK_RESULT`, and `BACKFORT_HOOK_EXIT_CODE`. If a hook needs a
credential for an external application, make the root-owned script obtain it
from its own protected source; do not put it in YAML or an argument.

If a post hook exists, Backfort invokes it after a completed pre hook even when
the pre hook fails, so cleanup scripts must be idempotent. Each hook has a
bounded `timeout_seconds` (300 seconds by default; 1–86400 allowed). A timed
out pre hook stops archive creation and still runs the post hook for cleanup;
a timed out or failed post hook makes the command fail with exit code `3` even
if a completed backup was already published. On an ordinary
`INT` or `TERM` during the backup pipeline, Backfort also attempts the post
hook. `SIGKILL` and host power loss cannot be intercepted, so every cleanup
hook must remain safe to run again manually.

For a Compose application, prefer a maintenance-mode hook or an engine-aware
database dump over stopping containers blindly. Keep the live database volume
out of `volumes`; Backfort's SQL/native dumps are the portable recovery input.

### Quick file backup

Use `quick` when a directory needs a proper backup immediately but does not yet
have a saved YAML job. It builds a strict temporary job and runs the standard
archive, checksum, atomic publication, and copy-policy pipeline:

```bash
sudo backfort.sh quick /etc /srv/www/site \
  --name site-before-upgrade \
  --to /var/backups/backfort \
  --to rclone:company-s3:company-backups/backfort/site \
  --min-copies 2 \
  --exclude '*.log' \
  --exclude '*/cache/*'
```

Paths may appear before or after options. Repeat `--to` for local and rclone
destinations; `rclone:REMOTE:PATH` supports AWS S3, DigitalOcean Spaces, Vultr
Object Storage, Cloudflare R2, FTP, Dropbox, Yandex Disk, pCloud, and other
configured rclone providers. `--exclude` uses the normal GNU tar patterns, and
`--follow-symlinks` is opt-in. `-n` validates and prints the plan without
writing a backup or recovery config.

On a real run, the non-secret job is saved as
`$XDG_STATE_HOME/backfort/quick/NAME.yaml`, or
`$HOME/.local/state/backfort/quick/NAME.yaml` when `XDG_STATE_HOME` is absent.
Use `--state-directory DIRECTORY` to select another protected location, then
reuse the saved file for `list`, `verify`, `restore`, or `prune`.

Quick backups derive their generated `host_id` from the local short hostname
and job name, so the same quick name on separate servers does not collide in a
shared destination. If hosts deliberately share a hostname, set a distinct
valid identifier explicitly:

```bash
sudo env BACKFORT_QUICK_HOST_ID=web-01 \
  /opt/backfort/backfort.sh quick /srv/app --name before-upgrade \
  --to rclone:cloudflare-r2:production-backups/backfort/app
```

### Docker Compose sources

A `docker_compose` source is explicit by design. Backfort copies only the
listed Compose files, volumes and bind mounts; it never automatically includes
`.env`, arbitrary project files or every mounted path. List database services
explicitly too—an image name is never used to infer a production backup plan.

```yaml
source:
  type: docker_compose
  project_dir: /srv/crm
  files: [compose.yaml, compose.production.yaml]
  # Bounds Docker/Compose calls and every database dump; default: 3600.
  command_timeout_seconds: 3600

  # These are logical volume names from the Compose project. They must not be
  # live database volumes; database consistency comes from the dump below.
  volumes: [uploads, documents]
  # Must already be present locally and contain GNU tar and a `timeout`
  # binary (present in common Debian- and Alpine-based images).
  volume_helper_image: registry.example/backfort-volume-helper@sha256:REPLACE_WITH_DIGEST

  # Paths are relative to project_dir and must stay inside it.
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
```

`docker compose config` resolves each configured logical volume to its actual
Docker volume name. Before a run, `doctor` verifies the Compose configuration,
selected services, selected volumes and the helper image. The helper runs with
no network, a read-only root filesystem and a read-only source-volume mount.
Backfort drops every Linux capability, then adds only `DAC_READ_SEARCH` so a
trusted helper can archive application-owned `0700` directories. Choose a
pinned image that includes `tar` and a `timeout` binary and runs that command
as root: the archive is wrapped in an in-container `timeout`, so it is the
container's own PID 1 and self-terminates on expiry even if Backfort's host-
side `docker` client is killed first. The helper has no writable mount:
Backfort captures its archive stream into its protected temporary workspace.

The `password_env` value is the **name** of a host environment variable, not a
password. Backfort passes its value into the target container using the engine's
password environment variable; it neither places the secret in its command
arguments nor stores it in the bundle metadata. `command_timeout_seconds`
applies to Docker/Compose checks, helper containers, container copies, and
logical/native database dumps. Each database dump, restore import, and the
volume helper's own archive command additionally runs behind an in-container
`timeout`, so a runaway process is reaped inside the container rather than
merely detached from a killed host-side client; this requires the database
service and volume helper images to provide a `timeout` binary (present in
common Debian- and Alpine-based images). Its default is one hour, and it
accepts 1–86400
seconds so an operator can match the timeout to the largest expected dump.

Database engine settings are as follows:

| Engine | Backup artifact | Required extra fields |
| --- | --- | --- |
| `postgres` | Custom-format `.dump` per database and optional `globals.sql`; set `format: sql` for a portable plain SQL dump | `databases`, optional `include_globals`, optional `format` (`custom` by default or `sql`) |
| `mysql` | Logical `.sql` dump with routines, events and triggers | `databases` |
| `mariadb` | Logical `.sql` dump with routines, events and triggers | `databases` |
| `mssql` | Native `.bak` made with `COPY_ONLY, CHECKSUM` | `databases`, `backup_directory` inside the container |
| `oracle` | Full Oracle Data Pump `.dmp` | `connect`, Oracle directory object `directory`, and its container `path` |

MS SQL containers must have `sqlcmd` available and permission to perform a
database backup. Oracle containers must have `expdp` available, the configured
directory object must map to `path`, and the account needs Data Pump full-export
privileges. These requirements are intentionally checked by the actual dump:
they vary between vendor images and cannot safely be guessed from image names.

### Quick Compose backup

For an immediate, one-off Compose backup, use `quick-compose`. It generates a
strict Backfort configuration and then uses the ordinary backup pipeline: the
archive has a checksum and metadata, and it is atomically published to every
successful destination. No password is placed in the generated configuration.

```bash
sudo backfort.sh quick-compose /srv/crm \
  --name crm-emergency \
  --file compose.yaml \
  --to /var/backups/backfort \
  --to rclone:company-s3:company-backups/backfort/crm \
  --min-copies 2 \
  --volume uploads \
  --volume-helper-image registry.example/backfort-volume-helper@sha256:REPLACE_WITH_DIGEST \
  --bind uploads:data/uploads \
  --db crm-postgres:postgres:postgres:backfort:BACKFORT_PG_PASSWORD:crm \
  --db crm-mysql:mysql:mysql:backfort:BACKFORT_MYSQL_PASSWORD:crm
```

`--to /absolute/path` creates a local copy. `--to
rclone:REMOTE:PATH` writes through an already configured rclone remote, so the
same command covers AWS S3, DigitalOcean Spaces, Vultr Object Storage,
Cloudflare R2, FTP, Dropbox, Yandex Disk, pCloud, and other rclone providers.
Repeat `--to` for independent copies; `--min-copies` defaults to one. Add `-n`
to plan and validate the operation without creating a backup.

By default the command includes `compose.yaml`; repeat `--file` for additional
Compose files. `--volume NAME` selects a non-database named volume and needs a
pre-pulled `--volume-helper-image`; `--bind NAME:RELATIVE_PATH` copies an
explicit project-relative bind mount. It never guesses which paths or volumes
belong in a backup.

`--db NAME:SERVICE:ENGINE:USER:PASSWORD_ENV:DB1,DB2` makes logical SQL dumps
from `postgres`, `mysql`, or `mariadb` service containers. PostgreSQL is
deliberately emitted as plain `.sql` in this quick command; MySQL and MariaDB
are also `.sql`. `PASSWORD_ENV` is the name of an exported host environment
variable. MS SQL and Oracle use native backup formats, so configure them in the
normal YAML job rather than pretending those artifacts are SQL.

This is a Compose project backup, not an export of a running container's
ephemeral writable layer or its image. Keep database volumes out of `--volume`:
their consistent recovery point is the selected database dump.

On an actual backup, after validation, Backfort saves the non-secret recovery configuration as
`$XDG_STATE_HOME/backfort/quick-compose/NAME.yaml`, or
`$HOME/.local/state/backfort/quick-compose/NAME.yaml` when `XDG_STATE_HOME` is
not set, and logs the exact path. Pass `--state-directory DIRECTORY` to choose
another protected location. Reuse that file for normal recovery operations:

```bash
sudo backfort.sh -c /root/.local/state/backfort/quick-compose/crm-emergency.yaml \
  list --job crm-emergency
sudo backfort.sh -c /root/.local/state/backfort/quick-compose/crm-emergency.yaml \
  restore latest --job crm-emergency --to /srv/recovery/crm
```

### Move a Compose project to a new server

`quick-compose` is the fast source-side step for a server move: it creates a
portable archive of explicitly selected Compose files, non-database volumes,
bind mounts, and logical PostgreSQL/MySQL/MariaDB dumps. It is intentionally
not a remote SSH orchestration command: the target is restored in stages so a
production volume or database is never overwritten by surprise.

On the source server, send a migration copy to an rclone remote. Include every
file, volume, bind mount, and database deliberately:

```bash
sudo backfort.sh --dry-run quick-compose /srv/crm \
  --name crm-server-move \
  --file compose.yaml --file .env \
  --to rclone:cloudflare-r2:backfort-migrations/crm \
  --volume uploads \
  --volume-helper-image registry.example/backfort-volume-helper@sha256:REPLACE_WITH_DIGEST \
  --bind uploads:data/uploads \
  --db crm-postgres:postgres:postgres:backfort:BACKFORT_PG_PASSWORD:crm

# Repeat without --dry-run once the plan is correct.
```

The real run writes a non-secret recovery config below
`$XDG_STATE_HOME/backfort/quick-compose/` (or
`$HOME/.local/state/backfort/quick-compose/`). Transfer that file to the new
server over an approved admin channel, configure the same rclone remote there,
then verify and restore into an empty staging directory. Recreate named volumes
and import the database only after inspecting the staged files.

The full target-side procedure, including volume extraction, database import,
cutover checks, and rollback criteria, is in
[Compose Migration](wiki/Compose-Migration.md). For a rehearsed migration plan
rather than a one-off command, start from
[examples/compose-migration.yaml](examples/compose-migration.yaml).

### Rclone destinations and copy policy

Configure the remote's credentials with `rclone config`, a root-owned rclone
configuration file, or rclone's supported environment-based configuration.
Backfort stores only the remote name and a non-empty relative path:

```yaml
- name: s3-offsite
  type: rclone
  remote: company-s3
  path: backups-bucket/backfort/server-01
```

Backfort uses rclone `copyto` and `moveto` for individual objects; it never
invokes `sync`. It uploads the payload, metadata and checksum before the
`.complete` marker.
Until the marker exists, a remote bundle is ignored by `list`, `verify`,
`restore` and `prune`.

`success.min_copies` is the minimum number of destinations that must accept a
completed bundle. Its default is one. When the minimum is reached but another
destination fails, Backfort exits with code `1` and reports a partial backup.
When the minimum is not reached, it exits with code `3` even though any copies
that did succeed remain available for recovery.

For an S3 remote, the first component of `path` is normally the bucket name.
For remotes such as Dropbox or Yandex Disk, it is simply a folder path.

S3-compatible storage is configured in rclone, not in Backfort. Common choices
are AWS S3, DigitalOcean Spaces, Vultr Object Storage, and Cloudflare R2; each
is represented here by a normal `type: rclone` destination. Give each provider
its own rclone remote name and use its bucket as the first `path` component:

| Provider | Example rclone remote | Example Backfort path |
| --- | --- | --- |
| AWS S3 | `aws-s3` | `production-backups/backfort/app-01` |
| DigitalOcean Spaces | `do-spaces` | `production-backups/backfort/app-01` |
| Vultr Object Storage | `vultr-object` | `production-backups/backfort/app-01` |
| Cloudflare R2 | `cloudflare-r2` | `production-backups/backfort/app-01` |

For example, `remote: cloudflare-r2` and `path:
production-backups/backfort/app-01` publish to the `production-backups` R2
bucket. Backfort treats all four the same way: upload payload, metadata and
checksum, then publish `.complete` last.

Exclude patterns use GNU tar matching rules. Symlinks are archived as links by
default. Set `follow_symlinks: true` only when copying the referenced data is
intentional.

### Prometheus metrics

Backfort can expose the result of each saved job through the Prometheus
node_exporter textfile collector. It still runs no daemon: after a persistent
`run`, Backfort atomically replaces one `backfort_<job>.prom` file for every
selected job, including one that fails its own preflight before an archive is
created. `--dry-run run`, `quick`, `quick-compose`, restore, prune, and
watchdog do not create metrics files.

```yaml
metrics:
  prometheus:
    textfile_directory: /var/lib/node_exporter/textfile_collector
```

Create the directory outside Backfort and grant the execution account write
access while leaving node_exporter read access. `doctor` checks that it is an
existing, writable, non-symlink directory. If it becomes unavailable after a
backup begins, Backfort logs a `kind=metrics` warning and preserves the backup
command's real exit code; monitoring output must not invalidate a recoverable
copy.

If a job's preflight fails—for example a source vanished, Docker Compose is
unavailable, or a database `password_env` is unset—`run` records that job with
exit code `3`, zero payload/copy values, and `duration=0`. It also emits the
ordinary failure notification with `stage=preflight`, then continues with the
other selected jobs. `doctor` remains strict and stops with code `2` so you can
repair a configuration before the scheduled window. If the **collector
directory itself** fails preflight, no metric can safely be written; Backfort
does not start any selected job and sends a failure notification instead.

Every file contains the following gauges, labelled only with the stable
`host` and `job` identifiers:

| Metric | Meaning |
| --- | --- |
| `backfort_last_run_success` | `1` for a fully successful last run, otherwise `0` |
| `backfort_last_run_exit_code` | Backfort result: `0`, `1`, or `3` |
| `backfort_last_run_timestamp_seconds` | UTC Unix time when the job run ended |
| `backfort_last_run_duration_seconds` | Duration of the last job run |
| `backfort_last_backup_size_bytes` | Payload size when one was created, otherwise `0` |
| `backfort_last_successful_copies` | Destinations that accepted that run's bundle |
| `backfort_last_failed_copies` | Destinations that rejected that run's bundle |

Backup IDs, source paths, destination paths, error text, and credentials are
never labels or values, avoiding both secret exposure and unbounded label
cardinality. Alert on a failed last run, for example:

```promql
backfort_last_run_success == 0
```

Use `backfort_last_run_timestamp_seconds` together with your expected schedule
to alert when no run has completed recently. See the [Monitoring and Metrics
wiki page](wiki/Monitoring-and-Metrics.md) for a node_exporter setup and query
examples.

### Notifications

Notifications are optional and never change a command's exit status: a dead
network, unavailable `curl`, missing token, or a rejected remote channel emits
a warning and leaves the backup, restore, prune, or watchdog result intact.
Secrets are always referenced by environment-variable name; their values never
go in YAML, Backfort logs, messages, or process arguments.

```yaml
notifications:
  enabled: true
  defaults:
    events: [failure, partial, recovery, watchdog]
    antiflood_hours: 4
    digest: off                 # or daily
  channels:
    - name: ops-telegram
      type: telegram
      token_env: BACKFORT_TG_TOKEN
      chat_id_env: BACKFORT_TG_CHAT
      thread_id_env: BACKFORT_TG_THREAD  # optional
      events: [failure, watchdog]
    - name: monitoring-ntfy
      type: ntfy
      server: https://ntfy.example.net
      topic_env: BACKFORT_NTFY_TOPIC
      priority: urgent
```

The fixed event set is `success`, `partial`, `failure`, `recovery`, `watchdog`,
`restore_success`, `restore_failure`, `prune`, `digest`, and reserved
`drill_failure`.
Channels without an `events` list inherit `defaults.events`. Success is opt-in:
after the initial success, Backfort records per-job status and sends `recovery`
instead only when a job previously failed or was partial. `failure`, `partial`,
and `watchdog` are limited per channel and job by `antiflood_hours`; a suppressed
send is reported as `notify_suppressed` on stderr.

`run` uses the same `failure` event when a selected job cannot pass preflight.
Its event has `stage=preflight`, no backup ID, and a redacted generic error; the
structured log carries the exact safe diagnostic. This distinguishes a failed
precondition from a failed archive or publish, while keeping the alert contract
uniform across Telegram, ntfy, webhooks, and SMTP.

Set `defaults.digest: daily` to collect `success` and `prune` activity in the
state directory. The first later Backfort event flushes the prior day's digest,
so no resident daemon is needed. A digest webhook is explicitly
`event: "digest"` with blank job/backup/error fields and `stage: "digest"`; it
never accidentally inherits a later failure's context. Channels may opt into
`success`, `prune`, or `digest` to receive it.

Telegram requires `BACKFORT_TG_TOKEN` and `BACKFORT_TG_CHAT`; `BACKFORT_TG_THREAD`
is optional. ntfy requires `BACKFORT_NTFY_TOPIC`. Webhooks require a URL in
`BACKFORT_WEBHOOK_URL` and may receive newline-separated `Header: value` lines
from `BACKFORT_WEBHOOK_HEADERS`. Telegram uses HTML for trusted template markup
but automatically retries once as plain text when Telegram rejects that markup,
so a malformed entity cannot lose an alert. SMTP channels check their configured
username and password environment variables and submit through a locally
configured `msmtp` or `sendmail`-compatible binary. Authenticated remote SMTP
requires TLS: use legacy `starttls: true`, or `tls_mode: implicit` for port 465;
`starttls: false` is rejected before delivery. Backfort emits UTF-8
`Date`, `Message-ID`, and `Content-Type` headers. Run `doctor` to see only the
names and readiness of every configured channel, never their secret values.

#### Message templates

An alert should let the on-call operator act without opening documentation.
Text channels (`telegram`, `ntfy`, and `smtp`) therefore render an actionable
default per event. A channel may replace one default completely with
`templates.<event>`; webhooks always retain their structured JSON body.

```yaml
notifications:
  channels:
    - name: ops-telegram
      type: telegram
      token_env: BACKFORT_TG_TOKEN
      chat_id_env: BACKFORT_TG_CHAT
      events: [failure, watchdog]
      templates:
        failure: "<b>💥 {{job}}</b>\n{{error}}\n<code>{{restore_hint}}</code>"
        watchdog: "No backup for {{job}}: {{last_backup_age}} > {{threshold}}"
```

The built-in `failure` message includes `job`, `host`, its redacted `error`,
and a copy-pasteable `{{restore_hint}}`, for example:

```text
sudo backfort.sh -c /etc/backfort/config.yaml restore server-01_important-files_20260925T021500Z_a91f3c2d --to /srv/restore-IMPORTANT-FILES
```

Every component in that hint is shell-quoted. It is emitted only when a job and
completed-backup ID are known.

| Placeholder | Meaning |
| --- | --- |
| `{{event}}`, `{{host}}`, `{{exit_code}}` | event name, configured host, command exit code |
| `{{job}}`, `{{id}}` | job and backup ID when the event has them |
| `{{size}}`, `{{duration}}` | human-readable backup size and run duration |
| `{{error}}` | redacted, bounded failure reason |
| `{{destinations}}`, `{{failed_destinations}}` | successful and failed publish targets |
| `{{target}}` | restore directory for restore events |
| `{{last_backup_age}}`, `{{threshold}}` | watchdog age and policy limit |
| `{{pinned_count}}`, `{{freed}}` | copies removed and space reclaimed by prune |
| `{{restore_hint}}` | safe restore command for backup-result and stale-watchdog events |

Only these placeholders are accepted. A template is a string of at most 1000
bytes; malformed braces or an unknown placeholder reject the configuration
before a command starts. Rendered text is capped at 20 lines of 400 bytes, and
Telegram messages at 4096 bytes, with UTF-8-safe `...` truncation.

For Telegram, every substituted value is redacted and HTML-escaped before it
is inserted. Literal HTML in a template is intentionally left intact because
the configuration is trusted and root-owned; use it for tags such as `<b>` or
`<code>`, never for untrusted values.

### Compression

Supported methods:

| Method | Level | Filename |
| --- | ---: | --- |
| `gzip` | 1-9 | `.tar.gz` |
| `zstd` | 1-19 | `.tar.zst` |
| `none` | ignored | `.tar` |

`gzip` level 6 is the default.

### Encryption

Secrets are referenced by environment-variable name and are never placed in
the YAML file or written to logs.

For `age`, provide one recipient while backing up, or a list of recipient
environment variables for independent recovery keys. Provide an identity file
while performing a full verification or restore:

```yaml
encryption:
  method: age
  recipients_env:
    - BACKFORT_AGE_RECIPIENT_PRIMARY
    - BACKFORT_AGE_RECIPIENT_RECOVERY
  identity_file_env: BACKFORT_AGE_IDENTITY_FILE
```

```bash
export BACKFORT_AGE_RECIPIENT_PRIMARY='age1...'
export BACKFORT_AGE_RECIPIENT_RECOVERY='age1...'
export BACKFORT_AGE_IDENTITY_FILE='/root/.config/backfort/age.key'
```

`recipient_env` remains supported for a single existing recipient, but cannot
be used together with `recipients_env`. The production server may omit every
private identity entirely. In that case it can create encrypted backups and run
`verify --quick`, but it cannot decrypt, fully verify, or restore them.

GPG has two mutually exclusive modes. The existing symmetric mode uses a
password from an environment variable:

```yaml
encryption:
  method: gpg
  password_env: BACKFORT_GPG_PASSWORD
```

Backfort passes the password through a pipe-backed dedicated file descriptor,
not a command-line argument or Bash here-string temporary file. It configures
GPG with iterated SHA-512 S2K at the
maximum OpenPGP count supported by GnuPG.

For asymmetric GPG, the backup server imports **only public keys** and encrypts
to exact primary-key fingerprints. This lets a compromised backup writer create
new copies but not decrypt historic ones. Use either a single `recipient_env`
or a resilient `recipients_env` list; the variable values must be 40- or
64-hex-character primary fingerprints:

```yaml
encryption:
  method: gpg
  recipients_env:
    - BACKFORT_GPG_RECIPIENT_PRIMARY
    - BACKFORT_GPG_RECIPIENT_RECOVERY
  # Optional: needed only when the recovery private key is passphrase-protected
  # and its GnuPG agent has not already unlocked it.
  identity_password_env: BACKFORT_GPG_IDENTITY_PASSWORD
```

Prepare and verify the recovery key on a trusted recovery machine. Export only
its public half to the backup writer:

```bash
# Trusted recovery machine: record this full fingerprint out of band.
gpg --quick-generate-key 'Backfort recovery <recovery@example.test>' default default never
gpg --fingerprint 'Backfort recovery <recovery@example.test>'
gpg --armor --export FINGERPRINT > backfort-recovery-public.asc

# Backup writer: import the verified public export; never import its private key.
sudo gpg --batch --import backfort-recovery-public.asc
export BACKFORT_GPG_RECIPIENT_PRIMARY='0123456789ABCDEF0123456789ABCDEF01234567'
```

Backfort checks that every configured fingerprint is syntactically exact and
already present in the local keyring during `doctor`; it never retrieves keys
from the network. It deliberately encrypts to the exact configured fingerprint,
not an ambiguous email address or short key ID. On the separate recovery host,
import the private key through your approved key-handling process. For an
unattended full verification or restore, set the optional
`BACKFORT_GPG_IDENTITY_PASSWORD` from a secret manager; otherwise unlock the
private key through the local GnuPG agent first. Do not copy that private key or
its passphrase to the backup writer.

### Detached Minisign signatures

SHA-256 detects accidental corruption, but an attacker able to alter a storage
destination can replace both a payload and its checksum. Enable Minisign to
publish a detached signature for the final payload and verify it before the
checksum is trusted:

```yaml
signing:
  method: minisign
  secret_key_env: BACKFORT_MINISIGN_SECRET_KEY
  public_key_env: BACKFORT_MINISIGN_PUBLIC_KEY
```

`BACKFORT_MINISIGN_SECRET_KEY` contains the absolute path to a root-owned,
non-symlink private key file. `BACKFORT_MINISIGN_PUBLIC_KEY` contains the
public-key text. Backfort needs the private key only to create a backup and the
public key to verify or restore it. The private key must be usable by a
non-interactive service; protect that host and key file accordingly.

This protects against alteration of a destination by someone who lacks the
signing key. It does **not** protect against an attacker who controls the
backup host and its signing key. Use a separate verification host, immutable
storage, or both for that threat model.

Deferred work—including offline recovery, a recovery kit and key rotation—is
tracked in the [security roadmap](docs/security-roadmap.md).

## Backup format and atomic publication

A backup ID contains the host, job, UTC timestamp, and an eight-character run
identifier:

```text
server-01_important-files_20260915T021500Z_a91f3c2d
```

Each unsigned completed local or rclone backup consists of four files; a signed
backup has a fifth detached signature. A pinned backup has one additional
runtime marker:

```text
<id>.tar.gz[.age|.gpg]  # payload
<id>.metadata.json      # self-describing manifest
<id>.sha256             # checksum of the final payload
<id>.minisig            # optional Minisign signature of the final payload
<id>.complete           # commit marker written last
<id>.pinned             # optional pin timestamp and human-readable reason
```

The manifest is also stored inside the tar archive as `manifest.json`. New
backups declare `file_hash_algorithm: sha256`. Every regular file in the
`entries` index has a `sha256` value alongside its path, type, size, and mtime;
directories and links deliberately do not have a file-content hash. Source
data is stored below `data/`. A Compose restore contains `compose/`,
`volumes/<logical-name>/data.tar`, `bind-mounts/<name>/` and
`databases/<database-name>/` below that root. Backfort writes every destination
file through a temporary name and publishes `.complete` last. For a local
destination it synchronizes the payload, metadata, checksum and optional
signature before that marker, then synchronizes the marker and destination
directory. Removal uses the reverse safety boundary: `.complete` is removed
first, so an interrupted local or remote deletion can leave only harmless
orphan files, never a partial bundle presented as recoverable. `list`, `status`,
`watchdog`, `diff`, `verify`, `restore`, and `prune` ignore bundles without this marker.
Automatic lookup is host-scoped: a shared destination can hold several hosts'
copies of one job without one server listing, restoring, retaining, or judging
another server's copies as its own.

For recovery fidelity, Backfort archives and restores POSIX ACLs, extended
attributes (including Linux file capabilities), sparse extents, timestamps, and
numeric ownership. Run restores with appropriate privilege when original
ownership must be recreated. A live file that changes while GNU tar reads it is
reported by tar but no longer aborts the whole version; the manifest describes
the files actually captured. FIFOs, device nodes, and names that cannot be
represented safely in the portable JSON manifest (control characters,
leading-space path components, or invalid UTF-8) are omitted with a structured
pack warning instead of invalidating the rest of the backup.

## Verification

Quick verification checks that all required bundle files exist, verifies a
configured Minisign signature, then compares the payload against its SHA-256
checksum:

```bash
backfort.sh -c /etc/backfort/config.yaml verify BACKUP_ID --quick
```

Full verification additionally decrypts and decompresses the payload, reads
the entire tar archive, checks entry types and paths, compares the internal
manifest with the external metadata, and recomputes SHA-256 for every regular
file in `data/` against the manifest:

```bash
backfort.sh -c /etc/backfort/config.yaml verify BACKUP_ID --full
```

The per-file pass detects a changed, truncated, swapped, or missing regular
file even when a damaged payload was given a new outer checksum. `--quick`
remains intentionally fast and checks only the final payload checksum (and an
optional signature); schedule `--full` and use it before every recovery drill.
Backups written before per-file hashes existed remain restorable and receive
the established archive-level checks, but cannot receive the new per-file
pass. SHA-256 detects accidental corruption. A configured detached signature
makes a payload and manifest substitution detectable when the attacker does
not have its private signing key; immutable storage is still recommended.

## Restore safety

Restore requires an explicit absolute target directory. The directory must be
new or empty. Backfort verifies a configured signature and checksum, decrypts
and decompresses the archive, performs the same available per-file SHA-256
pass as `verify --full`, rejects unexpected archive paths and special device
entries, and extracts without restoring archived ownership.

Backfort deliberately has no in-place restore and no `--force` option. A failed
extraction may leave partial data in the restore target for inspection; it never
deletes an existing restore directory automatically.

For a Compose backup, restore into a new directory first, inspect the recovered
Compose files and perform a deliberate recovery into an isolated project. For
example, restore a selected named-volume archive only into a newly created,
stopped recovery volume:

```bash
docker volume create crm-recovery-uploads
docker run --rm --network none \
  -v crm-recovery-uploads:/target \
  -v /srv/recovery/volumes/uploads:/backup:ro \
  registry.example/backfort-volume-helper@sha256:REPLACE_WITH_DIGEST \
  tar --extract --file /backup/data.tar --directory /target
```

For a Compose backup, `restore-compose` performs the same validated staging
restore and prints an inventory of Compose files, bind mounts, volume archives,
and database artifacts. It does not deploy files, start services, recreate
volumes, or write data into a database by default:

```bash
backfort.sh -c /etc/backfort/config.yaml \
  restore-compose latest --job crm --to /srv/recovery/crm
```

After preparing an isolated target Compose project yourself and starting only
its database services, it can import the staged logical PostgreSQL, MySQL and
MariaDB dumps. This remains deliberately opt-in: the target project must be
named explicitly, and `--apply --confirm` is required. The command checks the
target Compose files and that each selected database service is running before
it sends a dump to a client inside the container.

```bash
# /srv/crm-recovery already contains reviewed Compose files, secrets and a
# fresh, running database service. Use a new staging directory for this run.
backfort.sh -c /etc/backfort/config.yaml \
  restore-compose latest --job crm --to /srv/recovery/crm-import \
  --project-dir /srv/crm-recovery --apply --confirm
```

PostgreSQL custom dumps use `pg_restore --clean --if-exists`; plain PostgreSQL
dumps use `psql` with `ON_ERROR_STOP`; MySQL and MariaDB imports retain the
database directives from their dumps. PostgreSQL global-role artifacts,
MS SQL Server `.bak` files, and Oracle exports always require a reviewed,
vendor-native manual procedure. The assistant never runs `docker compose up`,
copies staged files into the target, extracts a volume, or applies a dump
without the two explicit flags.

## Interactive restore

When responding manually to an incident, choose a completed version without
looking up its backup ID first:

```bash
backfort.sh -c /etc/backfort/config.yaml \
  restore --pick --job important-files --to /srv/backfort-restore
```

With one configured job, `--job` is optional. With multiple jobs it is
required. Backfort prints every completed copy that is available on the chosen
destination (or across all of the job's destinations), newest first:

```text
#   backup_id                                             age          size       destination
1   server-01_important-files_20260925T021500Z_a91f3c2d  3h12m ago    1.2 GiB    local
2   server-01_important-files_20260924T021500Z_91e54cda  1d 3h ago    1.1 GiB    s3-offsite
Restore #> 2
selected=server-01_important-files_20260924T021500Z_91e54cda to=/srv/backfort-restore
```

Enter a number, `q`, or an empty line to cancel. `--pick` requires both stdin
and stdout to be real terminals, so it cannot block cron, systemd, or a pipe.
For scheduled recovery automation, always pass an explicit backup ID instead.
After choosing a version, Backfort follows the same checksum, signature,
decryption, path, and empty-target checks as ordinary `restore`.

## Retention

Retention is evaluated independently for each job and destination:

```yaml
retention:
  keep_last: 3
  keep_daily: 7
  keep_weekly: 4
  keep_monthly: 6
  min_keep: 1       # recovery floor; this many newest ordinary copies survive
  max_age_days: 90  # optional expiry for older unpinned copies
```

The retained set is the union of:

- the newest `keep_last` backups;
- the newest backup from each of the latest N represented UTC days;
- the newest backup from each of the latest N represented ISO weeks;
- the newest backup from each of the latest N represented UTC months.

`min_keep` is a positive safety floor and defaults to `1`. The newest N
ordinary (unpinned) completed copies are never removed by GFS rotation or
`max_age_days`; set it higher when the recovery policy requires several
independent rollback points.

`max_age_days` is optional. When set to a positive integer, an unpinned copy
older than that many full 24-hour periods is deleted by `prune` even if the
GFS rules above would otherwise retain it, except for the `min_keep` floor.
This is useful for a clear storage ceiling without allowing a prolonged backup
failure to erase the last recovery copy. Pinned copies are explicit recovery
points and remain outside both GFS and this age expiry; unpin them when their
longer lifetime is no longer wanted.

`keep_last` and `min_keep` must each be at least one. Preview every deletion
before enabling a scheduled prune:

```bash
backfort.sh -c /etc/backfort/config.yaml prune --dry-run
backfort.sh -c /etc/backfort/config.yaml prune
```

Pruning is deliberately separate from `run`. This permits a
different systemd service and a separately scoped rclone credential profile.

If a bundle for the current `host_id` carrying a `.complete` marker is
malformed, pruning stops for that destination instead of guessing which files
are safe to remove. Completed objects whose IDs belong to another host are
outside this host's retention scope and are skipped before validation.

### Pinned backups

Use a pin for a recovery point that must outlive normal retention—typically
right before a migration, upgrade, or risky manual operation:

```bash
backfort.sh -c /etc/backfort/config.yaml pin BACKUP_ID \
  --reason 'pre-migration freeze'
backfort.sh -c /etc/backfort/config.yaml unpin BACKUP_ID
```

`pin` without `--from DESTINATION` protects every completed copy of that ID;
with `--from`, it applies only to that destination. A pin is an atomic
`<id>.pinned` marker beside `.complete`, containing its UTC creation time and
optional reason. Repeating a pin with the same reason is a no-op; `unpin`
removes the marker and reports the number of affected destinations. Reasons are
single-line text up to 200 characters and are shown by `list`.

Pinned versions are outside GFS rotation and `max_age_days`: they never consume
`keep_last`, daily, weekly, or monthly slots, and are not hard-expired by
`prune`. `prune --dry-run` prints pinned copies as `reason=pinned`, and warns
if their number exceeds `keep_last`. This means pins can grow storage
indefinitely, so review and unpin obsolete recovery points yourself. `list`
marks pinned copies and includes `pinned` and optional `pinned_reason` fields
in JSON output.

### Deleting a date range

Use `delete` for a deliberate one-off purge outside retention. It requires one
job, both UTC calendar boundaries, and an explicit confirmation. `--until` is
inclusive: `2025-01-01` through `2025-01-31` covers every backup timestamp in
January UTC. Start with a dry run, then repeat the same command with
`--confirm`:

```bash
backfort.sh -c /etc/backfort/config.yaml delete \
  --job important-files --since 2025-01-01 --until 2025-01-31 --dry-run

backfort.sh -c /etc/backfort/config.yaml delete \
  --job important-files --since 2025-01-01 --until 2025-01-31 --confirm
```

Without `--from DESTINATION`, Backfort removes matching copies from every
destination of that job, including rclone/S3 and other cloud remotes. Add
`--from s3-offsite` to target one destination only. The command uses the same
lock and complete-bundle validation as `prune`; it deletes the commit marker
first on a remote so a partial deletion can never look like a recoverable
backup. Pinned copies are reported as retained and are never deleted by this
command—run `unpin BACKUP_ID` first if that is genuinely intended.

## Commands

```text
run [--job NAME]                         create backups
doctor [--job NAME]                      validate config, tools, paths, and env
list [--job NAME] [--json]               list completed backup copies
status [--job NAME]                      show the latest copy per destination
watchdog [--job NAME] [--max-age HOURS]  fail when a job has no fresh backup
diff ID1 ID2 [--from DEST] [--json]       compare two manifest indexes
pin BACKUP_ID [--from DEST] [--reason TEXT] protect completed backup copies
unpin BACKUP_ID [--from DEST]              remove pin markers
verify ID [--from DEST] [--quick|--full] verify a backup
verify latest --job NAME [...]           verify the newest job backup
restore ID --to DIR [--from DEST]        restore into a new or empty directory
restore --pick --to DIR [--job NAME] [--from DEST] choose a completed version interactively
restore-compose ID --to DIR [...]        stage a Compose backup and print recovery actions
restore-compose ID --to DIR --project-dir DIR --apply --confirm import supported logical DB dumps
prune [--job NAME] [--dry-run]           apply retention
delete --job NAME --since DATE --until DATE [--from DEST] [--confirm] delete one UTC period
quick-compose PROJECT_DIR --to DEST [OPTIONS] immediate Compose backup and SQL dumps
quick PATH [PATH ...] --to DEST [OPTIONS] immediate file/directory backup
-n, --dry-run                            plan run/restore/prune/delete/quick/quick-compose without writes
-c FILE                                  select an absolute config path
-V, --version                            print the version
```

Exit codes:

| Code | Meaning |
| ---: | --- |
| `0` | Complete success |
| `1` | Some destinations succeeded and some failed |
| `2` | Invalid CLI, configuration, dependency, or environment |
| `3` | Operational failure or backup success policy not met |

## Comparing versions

Compare two completed copies from the first destination configured for their
job, or select one destination explicitly with `--from`:

```bash
backfort.sh -c /etc/backfort/config.yaml diff ID1 ID2
backfort.sh -c /etc/backfort/config.yaml diff ID1 ID2 --from s3-offsite --json
```

`diff` is read-only and does not take the backup/prune lock. It streams only
each archive's `manifest.json`; it never extracts `data/` to disk. Results are
ordered as `added`, `removed`, then `modified`, with paths sorted inside each
group. `--json` returns the same groups plus `id1`, `id2`, and a `summary`.

Comparison uses manifest entry type, size, and mtime. A file whose content
changes while retaining the same size and mtime is reported as unchanged; use
`verify --full` or a recovery drill when content-level assurance is required.
Backups created before the entry index was added cannot be compared and are
reported as having no usable manifest index.

## Scheduling

A minimal cron example running at 02:15 UTC is:

```cron
CRON_TZ=UTC
15 2 * * * /opt/backfort/backfort.sh -c /etc/backfort/config.yaml run
```

Run pruning separately, preferably after reviewing its dry-run output. A daily
schedule is recommended when `max_age_days` sets an expiry above the
`min_keep` recovery floor:

```cron
45 3 * * * /opt/backfort/backfort.sh -c /etc/backfort/config.yaml prune
```

Both commands acquire the same non-blocking global lock. Capture stderr in
cron or use a systemd service so Backfort's structured logs reach the journal.

## Monitoring: dead man's switch

`watchdog` is a read-only freshness check for an external monitor, cron alert,
or healthcheck. It never acquires Backfort's run/prune lock and never creates,
removes, or uploads files, so it can run while a backup is active.

Configure the usual threshold and optional default job list at the top level:

```yaml
watchdog:
  max_age_hours: 26
  jobs: [important-files]
```

If `jobs` is omitted, every configured job is checked. `--job NAME` replaces
that default list with exactly one configured job. `--max-age HOURS` (integer
from 1 through 8760) overrides `watchdog.max_age_hours`; one of them is
required.

The newest valid, completed copy for the configured `host_id` across each
job's destinations is selected by the UTC timestamp embedded in its backup
ID—not by filesystem mtime. An incomplete or malformed bundle is ignored.
Fresh jobs print a machine-readable line to stdout and return `0`; every stale
job is reported on stderr and the command returns `3`. A missing completed
bundle is reported as
`last_backup=none`.

For example, check every 15 minutes and invoke your usual notification wrapper
only when the freshness check fails:

```cron
*/15 * * * * /opt/backfort/backfort.sh -c /etc/backfort/config.yaml watchdog || /usr/local/sbin/notify-backfort-watchdog
```

## Testing

The smoke test creates temporary source data and exercises configuration
validation, dry-run, backup, listing, quick and full verification, restore,
and content comparison:

```bash
bash -n backfort.sh tests/*.sh
bash tests/bash43-runtime.sh
bash tests/workspace-failure.sh
bash tests/smoke.sh
bash tests/host-scope.sh
bash tests/file-hashes.sh
bash tests/symlinks.sh
bash tests/quick.sh
bash tests/rclone-smoke.sh
bash tests/compose-smoke.sh
bash tests/restore-compose.sh
bash tests/crypto-smoke.sh
bash tests/gpg-asymmetric.sh
bash tests/watchdog.sh
bash tests/diff.sh
bash tests/pinned.sh
bash tests/delete-period.sh
bash tests/pick.sh
bash tests/notify.sh
bash tests/hooks.sh
bash tests/metrics.sh
bash tests/preflight-failure.sh
```

Run ShellCheck when it is available:

```bash
shellcheck backfort.sh tests/*.sh
```

## GitHub quality gates

Backfort's badges point to checks that are actually tracked in the repository:

| Guardrail | What it protects |
| --- | --- |
| [CI](.github/workflows/ci.yml) | Bash syntax and runtime on Bash 4.3, ShellCheck, YAML examples, the hermetic suite, and a real PostgreSQL/MySQL Compose backup-and-recovery round trip. |
| [Kubernetes](.github/workflows/kubernetes.yml) | Helm rendering/safety gates and real-image PVC backup, full verification, metadata recovery, cross-Job locking and non-root operation in an isolated kind cluster. |
| [Documentation](.github/workflows/documentation.yml) | Internal Markdown links across the README, Wiki sources, examples, and community documents, plus whitespace in changed files. |
| [CodeQL](.github/workflows/codeql.yml) | GitHub Actions workflow analysis on pull requests, `main`, and a weekly schedule. |
| [OpenSSF Scorecard](.github/workflows/scorecard.yml) | A weekly supply-chain review published to GitHub code scanning. |
| [Release metadata](.github/workflows/release-metadata.yml) | A `vX.Y.Z` tag must match the CLI version and the Changelog before release work proceeds. |
| [Dependabot](.github/dependabot.yml) | Weekly grouped GitHub Actions updates and Docker base-image updates. |

Every push and pull request runs CI on Ubuntu. Documentation-only changes also
run the lightweight link check. CI, Kubernetes, Documentation, CodeQL, and Scorecard can be
started manually from the Actions tab when diagnosing an environment-specific
failure; Release metadata intentionally starts only when a `vX.Y.Z` tag is
pushed.

## Current limitations

- Full backups only; no incremental mode or deduplication
- Kubernetes support covers mounted PVC files, not API resource discovery,
  CSI snapshots, database-Pod dump adapters or automatic cluster recovery
- No native S3, SSH or WebDAV destination; use rclone for supported remotes
- No built-in status page; use Prometheus textfile metrics or `watchdog`
- GNU userland is required
- No automatic in-place Compose restore or restore drill; recovery is staged
  into an empty directory and then deliberately applied to a separate project
- No database-volume snapshot may be treated as application-consistent; use the
  matching engine dump and exclude the live database volume from `volumes`
- MS SQL and Oracle support depends on tools and backup privileges inside the
  selected vendor container image

## License

[MIT](LICENSE) - Copyright 2026 Igor Sazonov.

Project repository: [github.com/shellharbor/backfort](https://github.com/shellharbor/backfort).
