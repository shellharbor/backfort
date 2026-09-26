# Backfort

**Your last line of data defense.**

Canonical repository: [github.com/shellharbor/backfort](https://github.com/shellharbor/backfort)

Backfort is a small, one-shot backup and recovery tool for Linux. It reads a
YAML configuration, creates full file backups, optionally compresses and
encrypts them, publishes each backup atomically to one or more local or rclone
destinations, and then exits. Scheduling belongs to cron or a systemd timer;
Backfort does not run a daemon.

Version 0.3 adds the first Docker Compose recovery adapter. A job can archive
explicit Compose files, selected named volumes, explicit bind mounts and
engine-aware database dumps, then publish the resulting bundle through the
same local and rclone destinations as a file backup.

## Features

- One Bash 4.3+ executable and one YAML configuration
- Strict configuration validation with unknown-key detection
- Full-file and directory backups with GNU tar include roots and excludes
- Docker Compose project snapshots: manifests, selected named volumes and bind
  mounts
- Logical PostgreSQL, MySQL and MariaDB dumps; native MS SQL and Oracle export
  artifacts
- `gzip`, `zstd`, or uncompressed archives
- Optional multi-recipient `age` or hardened symmetric GPG encryption
- Optional detached Minisign payload signatures for untrusted storage
- Multiple independent local or rclone destinations
- Offsite copies through rclone, including AWS S3, DigitalOcean Spaces, Vultr
  Object Storage, Cloudflare R2, FTP/FTPS, Dropbox, Yandex Disk, pCloud and
  other rclone-supported remotes
- Explicit `min_copies` policy for a successful backup
- Atomic publication using a final `.complete` marker
- Fast checksum verification and full decrypt/decompress/archive verification
- Safe restore into a new or empty directory
- Opt-in interactive restore version selection for a manual terminal session
- GFS-style `keep_last`, daily, weekly, and monthly retention
- Per-destination pinned backups for migration and upgrade recovery points
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

## Quick start

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

## Wiki

The expanded operational guide—with configuration, S3/rclone, Compose,
database, recovery, retention, automation, and troubleshooting examples—is in
[the GitHub Wiki sources](wiki/Home.md).

## Community and security

- [Contributing](CONTRIBUTING.md) — development and test expectations
- [Security policy](SECURITY.md) — responsible vulnerability reporting
- [Code of Conduct](CODE_OF_CONDUCT.md) — collaboration expectations
- [Support](SUPPORT.md) — safe, useful bug-reporting context

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

  # These are logical volume names from the Compose project. They must not be
  # live database volumes; database consistency comes from the dump below.
  volumes: [uploads, documents]
  # Must already be present locally and contain GNU or BusyBox-compatible tar.
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

The `password_env` value is the **name** of a host environment variable, not a
password. Backfort passes its value into the target container using the engine's
password environment variable; it neither places the secret in its command
arguments nor stores it in the bundle metadata.

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
`restore_success`, `restore_failure`, `prune`, and reserved `drill_failure`.
Channels without an `events` list inherit `defaults.events`. Success is opt-in:
after the initial success, Backfort records per-job status and sends `recovery`
instead only when a job previously failed or was partial. `failure`, `partial`,
and `watchdog` are limited per channel and job by `antiflood_hours`; a suppressed
send is reported as `notify_suppressed` on stderr.

Set `defaults.digest: daily` to collect `success` and `prune` activity in the
state directory. The first later Backfort event flushes the prior day's digest,
so no resident daemon is needed. Channels must opt into `success` or `prune` to
receive that digest.

Telegram requires `BACKFORT_TG_TOKEN` and `BACKFORT_TG_CHAT`; `BACKFORT_TG_THREAD`
is optional. ntfy requires `BACKFORT_NTFY_TOPIC`. Webhooks require a URL in
`BACKFORT_WEBHOOK_URL` and may receive newline-separated `Header: value` lines
from `BACKFORT_WEBHOOK_HEADERS`. SMTP channels check their configured username
and password environment variables and submit through a locally configured
`msmtp` or `sendmail`-compatible binary. Run `doctor` to see only the names and readiness
of every configured channel, never their secret values.

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

GPG support in 0.3 is symmetric:

```yaml
encryption:
  method: gpg
  password_env: BACKFORT_GPG_PASSWORD
```

Backfort passes the password through a dedicated file descriptor rather than
as a command-line argument. It configures GPG with iterated SHA-512 S2K at the
maximum OpenPGP count supported by GnuPG.

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
backups include an `entries` index with each path's type, size, and mtime for
read-only version comparison. Source data is stored below `data/`. A Compose
restore contains `compose/`,
`volumes/<logical-name>/data.tar`, `bind-mounts/<name>/` and
`databases/<database-name>/` below that root. Backfort writes every destination
file through a temporary name and publishes `.complete` last. `list`, `status`,
`watchdog`, `diff`, `verify`, `restore`, and `prune` ignore bundles without this marker.

## Verification

Quick verification checks that all required bundle files exist, verifies a
configured Minisign signature, then compares the payload against its SHA-256
checksum:

```bash
backfort.sh -c /etc/backfort/config.yaml verify BACKUP_ID --quick
```

Full verification additionally decrypts and decompresses the payload, reads
the entire tar archive, checks entry types and paths, and compares the internal
manifest with the external metadata:

```bash
backfort.sh -c /etc/backfort/config.yaml verify BACKUP_ID --full
```

SHA-256 detects accidental corruption. A configured detached signature makes a
payload substitution detectable when the attacker does not have its private
signing key; immutable storage is still recommended.

## Restore safety

Restore requires an explicit absolute target directory. The directory must be
new or empty. Backfort verifies a configured signature and checksum, decrypts and decompresses the
archive, rejects unexpected archive paths and special device entries, and
extracts without restoring archived ownership.

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

Import database artifacts only after reviewing the generated Compose project,
credentials and target names. Backfort does not automatically apply a dump to a
running database container. That intentional pause is the safety boundary that
prevents a recovery command from overwriting production data.

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
  max_age_days: 90  # optional hard expiry for unpinned copies
```

The retained set is the union of:

- the newest `keep_last` backups;
- the newest backup from each of the latest N represented UTC days;
- the newest backup from each of the latest N represented ISO weeks;
- the newest backup from each of the latest N represented UTC months.

`max_age_days` is optional. When set to a positive integer, an unpinned copy
older than that many full 24-hour periods is deleted by `prune` even if the
GFS rules above would otherwise retain it. This is useful for a clear storage
ceiling such as “never keep ordinary backups past 90 days.” Pinned copies are
explicit recovery points and remain outside both GFS and this age expiry; unpin
them when their longer lifetime is no longer wanted.

`keep_last` must be at least one. Preview every deletion before enabling a
scheduled prune:

```bash
backfort.sh -c /etc/backfort/config.yaml prune --dry-run
backfort.sh -c /etc/backfort/config.yaml prune
```

Pruning is deliberately separate from `run`. This permits a
different systemd service and a separately scoped rclone credential profile.

If any bundle carrying a `.complete` marker is malformed, pruning stops for
that destination instead of guessing which files are safe to remove.

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
schedule is recommended when `max_age_days` sets a hard expiry:

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

The newest valid, completed copy across each job's destinations is selected by
the UTC timestamp embedded in its backup ID—not by filesystem mtime. An
incomplete or malformed bundle is ignored. Fresh jobs print a machine-readable
line to stdout and return `0`; every stale job is reported on stderr and the
command returns `3`. A missing completed bundle is reported as
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
bash tests/smoke.sh
bash tests/rclone-smoke.sh
bash tests/compose-smoke.sh
bash tests/crypto-smoke.sh
bash tests/watchdog.sh
bash tests/diff.sh
bash tests/pinned.sh
bash tests/pick.sh
bash tests/notify.sh
bash tests/pick.sh
```

Run ShellCheck when it is available:

```bash
shellcheck backfort.sh tests/*.sh
```

Every push and pull request also runs these checks on Ubuntu in GitHub Actions.

## Version 0.3 limitations

- Full backups only; no incremental mode or deduplication
- No native S3, SSH or WebDAV destination; use rclone for supported remotes
- No hooks, metrics, or status page
- No per-file checksums inside the manifest; the complete payload is checksummed
- GPG encryption is symmetric only
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
