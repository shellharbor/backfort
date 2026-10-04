# Configuration

Backfort uses one strict YAML file. Unknown keys are errors, which prevents a
misspelled safety setting from silently being ignored.

## Configuration anatomy

```yaml
version: 1

settings:
  host_id: app-01
  state_directory: /var/lib/backfort
  temp_directory: /var/tmp/backfort
  lock_file: /run/backfort.lock
  min_free_mb: 1024

metrics:
  prometheus:
    textfile_directory: /var/lib/node_exporter/textfile_collector

destinations:
  - name: local
    type: local
    path: /var/backups/backfort
  - name: offsite
    type: rclone
    remote: cloudflare-r2
    path: production-backups/backfort/app-01

jobs:
  - name: application
    source:
      type: files
      paths: [/etc/myapp, /srv/myapp/uploads]
      exclude: ["*.log", "*/tmp/*", "*/node_modules/*"]
      follow_symlinks: false
    destinations: [local, offsite]
    success: {min_copies: 2}
    compression: {method: zstd, level: 10}
    encryption: {method: age, recipients_env: [BACKFORT_AGE_PRIMARY, BACKFORT_AGE_RECOVERY]}
    signing: {method: minisign, secret_key_env: BACKFORT_MINISIGN_SECRET_KEY, public_key_env: BACKFORT_MINISIGN_PUBLIC_KEY}
    retention: {keep_last: 7, keep_daily: 14, keep_weekly: 8, keep_monthly: 12, min_keep: 1}
```

## `settings`

| Key | Purpose |
| --- | --- |
| `host_id` | Stable identifier embedded in backup IDs and manifest metadata; it scopes automatic discovery in a shared destination. |
| `state_directory` | Backfort state, including notification state. Keep it root-owned. |
| `temp_directory` | Transient working directory. It must have enough space for a bundle. |
| `lock_file` | Shared lock for backup creation, prune, pin, unpin, and deletion. |
| `min_free_mb` | Minimum free space required before work starts. |

Choose a distinct, stable `host_id` for every server that writes to the same
local directory, bucket, or rclone path. Automatic selectors (`list`,
`status`, `latest`, `restore --pick`, `watchdog`, `prune`, and date-range
`delete`) use it to see only the current server's backups. An explicit backup
ID remains an operator-approved way to recover a copy made by another host.

All filesystem paths must be absolute. Backfort rejects `/`, traversal (`..`),
and self-referential source/destination layouts.

### Container path mapping

Docker does not change the YAML schema, but it changes which filesystem each
absolute path names. The paths in the configuration must name locations
**inside** the Backfort container, and each one must be backed by a deliberate
mount. For example, the maintained Docker example maps `/source` read-only,
`/backups` read-write, `/var/lib/backfort` to persistent state, and
`/var/tmp/backfort` to persistent working space:

```yaml
settings:
  state_directory: /var/lib/backfort
  temp_directory: /var/tmp/backfort
  lock_file: /var/lib/backfort/backfort.lock
destinations:
  - name: local
    type: local
    path: /backups
jobs:
  - name: container-files
    source: {type: files, paths: [/source], exclude: [], follow_symlinks: false}
```

The state, temporary work and local destination paths need writable persistent
mounts; the source normally needs a read-only mount. Do not point a container
job at an unmounted host path and assume it sees the host data. See [Docker
Deployment](Docker-Deployment) for the Compose sample, filesystem matrix and
security boundary.

Kubernetes uses the same YAML under the Helm chart's `config` value; Helm
deployment values are a separate schema. State and lock live below
`/var/lib/backfort/` on a shared PVC, work below `/var/tmp/backfort/` on a
disk-backed ephemeral volume, and each source is an explicit readonly PVC.
Credentials reference existing Secrets. Use [Kubernetes Deployment](Kubernetes-Deployment)
for the namespace, access-mode, scheduling and recovery contract.

## Prometheus textfile metrics

The optional `metrics.prometheus` block publishes the outcome of each
persistent saved-job run to node_exporter's textfile collector, including a
selected job that fails its own preflight before an archive is created:

```yaml
metrics:
  prometheus:
    textfile_directory: /var/lib/node_exporter/textfile_collector
```

`run` records an individual preflight failure as exit code `3` with zero
payload/copy values, emits a `failure` event with `stage=preflight`, and
continues the other selected jobs. `doctor` remains the strict readiness check
and exits `2` for the same problem. If the collector directory itself is
unusable, Backfort cannot write a metric; it stops before backup work and sends
the preflight failure event instead.

`textfile_directory` is required when `prometheus` is present. It must be an
absolute, existing, writable directory and cannot be a symlink. Backfort does
not create it: provision its ownership/permissions explicitly so the Backfort
account can write and node_exporter can read. See [Monitoring and
Metrics](Monitoring-and-Metrics) for the metric contract, safe file lifecycle,
and alert examples.

## File sources and excludes

`paths` is an explicit list. Directories are archived recursively and files are
included as files. Exclude rules use GNU tar patterns:

```yaml
source:
  type: files
  paths: [/etc, /srv/app/uploads]
  exclude:
    - "*.log"
    - "*/cache/*"
    - "*/tmp/*"
    - "*/.git/*"
  follow_symlinks: false
```

Keep `follow_symlinks: false` unless following the target is intentional.
Following a symlink can include data outside the visible source tree.

Backfort preserves POSIX ACLs, extended attributes, sparse extents, timestamps,
and numeric ownership in a normal file backup. Run recovery with suitable
privilege when original owners need to be recreated. A file that changes while
GNU tar reads it does not discard the whole version; tar reports the live-file
warning and the manifest records what was actually captured. For a portable,
safe manifest, FIFO/device entries and names with control characters,
leading-space components, or invalid UTF-8 are omitted with a structured pack
warning instead of making every other source file unrecoverable.

## Lifecycle hooks

Saved jobs can quiesce an application before Backfort begins the archive
pipeline, then undo that change afterwards. Hooks are executable files with
literal argument arrays; they are not shell command strings:

```yaml
hooks:
  pre:
    path: /usr/local/lib/backfort/hooks/crm-maintenance
    args: [enable]
    timeout_seconds: 120
  post:
    path: /usr/local/lib/backfort/hooks/crm-maintenance
    args: [disable]
    timeout_seconds: 120
```

The Backfort execution account must own each hook. It must be a regular
executable file, not a symlink, and group/other write permissions are rejected.
`doctor` checks this before a scheduled run. `--dry-run run` shows the planned
hooks without executing them.

Hooks receive a scrubbed environment, a safe system `PATH`, `LANG=C`, and only
the non-secret `BACKFORT_HOOK_PHASE`, `BACKFORT_HOOK_JOB`,
`BACKFORT_HOOK_BACKUP_ID`, `BACKFORT_HOOK_CONFIG_FILE`,
`BACKFORT_HOOK_SOURCE_TYPE`, `BACKFORT_HOOK_RESULT`, and
`BACKFORT_HOOK_EXIT_CODE` values. Do not place credentials in hook arguments
or YAML. A hook needing a credential must obtain it itself from protected local
state.

A failed `pre` hook stops archive creation. When `post` exists it is invoked
after the pre hook has returned, including after a pre failure, so it must be
idempotent. A failed post hook makes the Backfort command fail even if the
payload has already been published. Backfort attempts post cleanup after
ordinary `INT`/`TERM` during the backup pipeline; `SIGKILL` and power loss
remain the hook author's recovery responsibility.

`timeout_seconds` is optional per `pre` or `post` hook (default `300`, range
`1`–`86400`). A timed-out `pre` is a failed pre hook and still triggers the
post hook; a timed-out post makes the command fail. Keep the post action
idempotent so it can unfreeze a filesystem safely after a timeout.

## Docker Compose command timeouts

Compose sources can bound all Docker/Compose interactions—preflight calls,
volume helper, `docker cp`, `docker compose exec`, and database dumps—with one
source setting:

```yaml
source:
  type: docker_compose
  project_dir: /srv/crm
  files: [compose.yaml]
  command_timeout_seconds: 3600
```

The default is `3600`; the allowed range is `1`–`86400`. Choose a value larger
than the largest expected logical dump, but finite enough that a stuck daemon,
container client, or database cannot retain Backfort's lock forever.

## Runtime read cache

Backfort treats a configuration file as immutable for one command invocation
and reuses repeated YAML reads instead of starting `yq` again. For an rclone
destination it likewise takes one object-name listing per invocation and
reuses it for repeated existence checks. Start a new Backfort command after
editing YAML or changing remote objects outside Backfort; each new command
creates a fresh view.

## Copy policy

Every destination is attempted independently. `success.min_copies` is the
minimum number of destinations that must publish a complete bundle:

```yaml
destinations: [local, offsite]
success:
  min_copies: 2
```

If one destination succeeds and one fails while the minimum is one, Backfort
returns exit code `1` (partial success). If the required minimum is not met,
it returns `3` even though any completed copies remain available.

## Compression, encryption, and signing

```yaml
compression: {method: gzip, level: 6}   # gzip | zstd | none
encryption: {method: none}              # none | age | gpg
signing: {method: none}                 # none | minisign
```

For age, keep recipients in environment variables:

```bash
export BACKFORT_AGE_PRIMARY='age1...'
export BACKFORT_AGE_RECOVERY='age1...'
```

GPG supports two mutually exclusive modes. The backwards-compatible symmetric
mode uses only an environment-variable name in YAML:

```yaml
encryption:
  method: gpg
  password_env: BACKFORT_GPG_PASSWORD
```

Never add the secret value to YAML, a shell history entry, an example, or a
repository commit. Backfort supplies the value to GnuPG through a pipe-backed
file descriptor rather than command-line arguments or a Bash here-string
temporary file.

For asymmetric GPG, import verified public keys into the keyring of the account
that runs Backfort. Refer to one exact 40- or 64-hex primary fingerprint, or a
list of independent recovery fingerprints, through environment-variable names:

```yaml
encryption:
  method: gpg
  recipients_env:
    - BACKFORT_GPG_RECIPIENT_PRIMARY
    - BACKFORT_GPG_RECIPIENT_RECOVERY
  # Optional and used only while decrypting with a passphrase-protected key:
  identity_password_env: BACKFORT_GPG_IDENTITY_PASSWORD
```

The backup writer needs public keys only. `doctor` validates that every
fingerprint value is exact and already available locally; Backfort never
downloads a key and never accepts a short key ID or email address. The private
key remains on a separate recovery host. Set `identity_password_env` there for
unattended restore/full verification, or omit it when the local GnuPG agent has
already unlocked the private key. `password_env` cannot be combined with either
recipient setting.

Continue with [Destinations and S3](Destinations-and-S3) for offsite storage
and [Automation and Notifications](Automation-and-Notifications) for scheduled
runs. Monitoring is documented separately in [Monitoring and
Metrics](Monitoring-and-Metrics).
