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
    retention: {keep_last: 7, keep_daily: 14, keep_weekly: 8, keep_monthly: 12}
```

## `settings`

| Key | Purpose |
| --- | --- |
| `host_id` | Stable identifier embedded in backup IDs and manifest metadata. |
| `state_directory` | Backfort state, including notification state. Keep it root-owned. |
| `temp_directory` | Transient working directory. It must have enough space for a bundle. |
| `lock_file` | Shared lock for backup creation, prune, pin, unpin, and deletion. |
| `min_free_mb` | Minimum free space required before work starts. |

All filesystem paths must be absolute. Backfort rejects `/`, traversal (`..`),
and self-referential source/destination layouts.

## Prometheus textfile metrics

The optional `metrics.prometheus` block publishes the outcome of each real
saved-job run to node_exporter's textfile collector:

```yaml
metrics:
  prometheus:
    textfile_directory: /var/lib/node_exporter/textfile_collector
```

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

## Lifecycle hooks

Saved jobs can quiesce an application before Backfort begins the archive
pipeline, then undo that change afterwards. Hooks are executable files with
literal argument arrays; they are not shell command strings:

```yaml
hooks:
  pre:
    path: /usr/local/lib/backfort/hooks/crm-maintenance
    args: [enable]
  post:
    path: /usr/local/lib/backfort/hooks/crm-maintenance
    args: [disable]
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

For symmetric GPG, use only an environment-variable name in YAML:

```yaml
encryption:
  method: gpg
  password_env: BACKFORT_GPG_PASSWORD
```

Never add the secret value to YAML, a shell history entry, an example, or a
repository commit.

Continue with [Destinations and S3](Destinations-and-S3) for offsite storage
and [Automation and Notifications](Automation-and-Notifications) for scheduled
runs. Monitoring is documented separately in [Monitoring and
Metrics](Monitoring-and-Metrics).
