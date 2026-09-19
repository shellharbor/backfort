# Backfort

**Your last line of data defense.**

Canonical repository: [github.com/backfort/backfort](https://github.com/backfort/backfort)

Backfort is a small, one-shot backup and recovery tool for Linux. It reads a
YAML configuration, creates full file backups, optionally compresses and
encrypts them, publishes each backup atomically to one or more local
destinations, and then exits. Scheduling belongs to cron or a systemd timer;
Backfort does not run a daemon.

Version 0.1 is deliberately narrow. It provides a complete and testable
`files -> local -> verify -> restore -> prune` workflow before remote storage,
database adapters, hooks, and notifications are added.

## Features

- One Bash 4.3+ executable and one YAML configuration
- Strict configuration validation with unknown-key detection
- Full-file and directory backups with GNU tar include roots and excludes
- `gzip`, `zstd`, or uncompressed archives
- Optional `age` or symmetric GPG encryption
- Multiple independent local destinations
- Atomic publication using a final `.complete` marker
- Fast checksum verification and full decrypt/decompress/archive verification
- Safe restore into a new or empty directory
- GFS-style `keep_last`, daily, weekly, and monthly retention
- Global `flock` for mutating commands
- Read-only dry-run mode and environment diagnostics
- Structured, journal-friendly log lines

## Requirements

- Linux
- Bash 4.3 or newer
- [Mike Farah yq](https://github.com/mikefarah/yq) v4
- GNU `tar`, `coreutils`, `findutils`, `util-linux`, and `gzip`
- Optional: `zstd`, `age`, or GnuPG when those features are enabled

On Debian or Ubuntu, the base packages can be installed with:

```bash
sudo apt-get install bash coreutils findutils gzip tar util-linux
```

Install Mike Farah `yq` v4 using its official release or package. The Python
package with the same name is not compatible.

## Quick start

Clone the canonical repository:

```bash
git clone https://github.com/backfort/backfort.git
cd backfort
```

Install the executable and create the runtime configuration:

```bash
sudo install -d -m 0755 /opt/backfort /etc/backfort
sudo install -m 0755 backfort.sh /opt/backfort/backfort.sh
sudo install -m 0640 config.example.yaml /etc/backfort/config.yaml
sudoedit /etc/backfort/config.yaml
```

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

The configuration has four top-level keys:

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

jobs:
  - name: important-files
    source:
      type: files
      paths: [/etc/nginx, /var/www]
      exclude: ["*.log", "*/cache/*"]
      follow_symlinks: false
    destinations: [local]
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

Exclude patterns use GNU tar matching rules. Symlinks are archived as links by
default. Set `follow_symlinks: true` only when copying the referenced data is
intentional.

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

For `age`, provide a recipient while backing up and an identity file while
performing a full verification or restore:

```yaml
encryption:
  method: age
  recipient_env: BACKFORT_AGE_RECIPIENT
  identity_file_env: BACKFORT_AGE_IDENTITY_FILE
```

```bash
export BACKFORT_AGE_RECIPIENT='age1...'
export BACKFORT_AGE_IDENTITY_FILE='/root/.config/backfort/age.key'
```

The production server may omit the private identity entirely. In that case it
can create encrypted backups and run `verify --quick`, but it cannot decrypt,
fully verify, or restore them.

GPG support in 0.1 is symmetric:

```yaml
encryption:
  method: gpg
  password_env: BACKFORT_GPG_PASSWORD
```

Backfort passes the password through a dedicated file descriptor rather than
as a command-line argument.

## Backup format and atomic publication

A backup ID contains the host, job, UTC timestamp, and an eight-character run
identifier:

```text
server-01_important-files_20260915T021500Z_a91f3c2d
```

Each completed local backup consists of four files:

```text
<id>.tar.gz[.age|.gpg]  # payload
<id>.metadata.json      # self-describing manifest
<id>.sha256             # checksum of the final payload
<id>.complete           # commit marker written last
```

The manifest is also stored inside the tar archive as `manifest.json`. Source
data is stored below `data/`. Backfort writes every destination file through a
temporary name and publishes `.complete` last. `list`, `status`, `verify`,
`restore`, and `prune` ignore bundles without this marker.

## Verification

Quick verification checks that all four bundle files exist and compares the
payload against its SHA-256 checksum:

```bash
backfort.sh -c /etc/backfort/config.yaml verify BACKUP_ID --quick
```

Full verification additionally decrypts and decompresses the payload, reads
the entire tar archive, checks entry types and paths, and compares the internal
manifest with the external metadata:

```bash
backfort.sh -c /etc/backfort/config.yaml verify BACKUP_ID --full
```

SHA-256 detects accidental corruption. Without encryption, immutable storage,
or a future detached-signature feature, it does not protect against an attacker
who can replace both the payload and checksum.

## Restore safety

Restore requires an explicit absolute target directory. The directory must be
new or empty. Backfort checks the checksum, decrypts and decompresses the
archive, rejects unexpected archive paths and special device entries, and
extracts without restoring archived ownership.

Version 0.1 intentionally has no in-place restore and no `--force` option. A
failed extraction may leave partial data in the restore target for inspection;
Backfort never deletes an existing restore directory automatically.

## Retention

Retention is evaluated independently for each job and destination:

```yaml
retention:
  keep_last: 3
  keep_daily: 7
  keep_weekly: 4
  keep_monthly: 6
```

The retained set is the union of:

- the newest `keep_last` backups;
- the newest backup from each of the latest N represented UTC days;
- the newest backup from each of the latest N represented ISO weeks;
- the newest backup from each of the latest N represented UTC months.

`keep_last` must be at least one. Preview every deletion before enabling a
scheduled prune:

```bash
backfort.sh -c /etc/backfort/config.yaml prune --dry-run
backfort.sh -c /etc/backfort/config.yaml prune
```

Pruning is deliberately separate from `run` in version 0.1. This permits a
different systemd service and, for future remote destinations, separate delete
credentials.

If any bundle carrying a `.complete` marker is malformed, pruning stops for
that destination instead of guessing which files are safe to remove.

## Commands

```text
run [--job NAME]                         create backups
doctor [--job NAME]                      validate config, tools, paths, and env
list [--job NAME] [--json]               list completed backup copies
status [--job NAME]                      show the latest copy per destination
verify ID [--from DEST] [--quick|--full] verify a backup
verify latest --job NAME [...]           verify the newest job backup
restore ID --to DIR [--from DEST]        restore into a new or empty directory
prune [--job NAME] [--dry-run]           apply retention
-n, --dry-run                            plan run/restore/prune without writes
-c FILE                                  select an absolute config path
-V, --version                            print the version
```

Exit codes:

| Code | Meaning |
| ---: | --- |
| `0` | Complete success |
| `1` | Some destinations succeeded and some failed |
| `2` | Invalid CLI, configuration, dependency, or environment |
| `3` | Operational failure or no usable backup copy |

## Scheduling

A minimal cron example running at 02:15 UTC is:

```cron
CRON_TZ=UTC
15 2 * * * /opt/backfort/backfort.sh -c /etc/backfort/config.yaml run
```

Run pruning separately, preferably after reviewing its dry-run output:

```cron
45 3 * * 0 /opt/backfort/backfort.sh -c /etc/backfort/config.yaml prune
```

Both commands acquire the same non-blocking global lock. Capture stderr in
cron or use a systemd service so Backfort's structured logs reach the journal.

## Testing

The smoke test creates temporary source data and exercises configuration
validation, dry-run, backup, listing, quick and full verification, restore,
and content comparison:

```bash
bash -n backfort.sh tests/smoke.sh
bash tests/smoke.sh
```

Run ShellCheck when it is available:

```bash
shellcheck backfort.sh tests/smoke.sh
```

## Version 0.1 limitations

- File sources and local destinations only
- Full backups only; no incremental mode or deduplication
- No database or Docker adapters
- No S3, SSH, rclone, or WebDAV destinations
- No hooks, notifications, metrics, or status page
- No per-file checksums inside the manifest; the complete payload is checksummed
- GPG encryption is symmetric only
- GNU userland is required

The next planned vertical slice is remote publication to S3 and SSH with the
same commit-marker contract, followed by PostgreSQL, MySQL, and Docker volume
sources.

## License

[MIT](LICENSE) - Copyright 2026 Igor Sazonov.

Project repository: [github.com/backfort/backfort](https://github.com/backfort/backfort).
