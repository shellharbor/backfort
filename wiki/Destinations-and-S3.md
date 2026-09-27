# Destinations and S3

Backfort writes to a local directory or a preconfigured rclone remote. Every
destination receives a full independent bundle; Backfort never uses `sync` and
will not infer permission to delete unrelated remote files.

## Local recovery copy

Keep one local copy for the fastest restore:

```yaml
destinations:
  - name: local
    type: local
    path: /var/backups/backfort
```

The process account must be able to create this directory and write files to
it. Do not put it inside a source directory, or a backup could include its own
previous backup data. Backfort writes each artifact through a temporary name,
synchronizes the payload evidence, then publishes and synchronizes `.complete`.
This keeps a power loss from making an incomplete local copy appear
recoverable.

## Rclone destination

Configure the storage account outside Backfort with `rclone config`, a
root-owned rclone configuration, or rclone's supported environment-based
configuration. Then refer to the remote only by name:

```yaml
destinations:
  - name: r2-offsite
    type: rclone
    remote: cloudflare-r2
    path: production-backups/backfort/app-01
```

The `path` is relative to the rclone remote. For S3-compatible storage, its
first component is normally the bucket name.

## Shared destination safety

Several Backfort hosts may use the same local destination or rclone path when
each has a unique, stable `settings.host_id`. Their bundles can coexist even
when the job names are identical: automatic `list`, `status`, `latest`,
`restore --pick`, `watchdog`, `prune`, and date-range `delete` inspect only
the configured host's IDs. This prevents one server's fresh copy from hiding a
stale server and prevents retention from deleting another server's backups.

Use a full backup ID only when you intentionally need a reviewed cross-host
recovery copy.

## S3-compatible providers

The following providers are ordinary rclone S3-compatible remotes from
Backfort's perspective. Create a separate rclone remote for each account or
provider, then use the bucket as the first path component.

| Provider | Example remote name | Backfort destination |
| --- | --- | --- |
| AWS S3 | `aws-s3` | `remote: aws-s3`, `path: production-backups/backfort/app-01` |
| DigitalOcean Spaces | `do-spaces` | `remote: do-spaces`, `path: production-backups/backfort/app-01` |
| Vultr Object Storage | `vultr-object` | `remote: vultr-object`, `path: production-backups/backfort/app-01` |
| Cloudflare R2 | `cloudflare-r2` | `remote: cloudflare-r2`, `path: production-backups/backfort/app-01` |

Example with a fast local copy and R2 offsite copy:

```yaml
destinations:
  - name: local
    type: local
    path: /var/backups/backfort
  - name: r2-offsite
    type: rclone
    remote: cloudflare-r2
    path: production-backups/backfort/app-01

jobs:
  - name: app
    # source omitted here
    destinations: [local, r2-offsite]
    success: {min_copies: 2}
```

The same shape works for AWS, DigitalOcean, or Vultr—only `remote` changes.

## Why `.complete` matters

On local and rclone destinations, Backfort publishes:

```text
<id>.tar.gz                 payload
<id>.metadata.json          backup manifest
<id>.sha256                 payload checksum
<id>.minisig                optional Minisign signature
<id>.complete               final commit marker
```

For a remote destination, payload, metadata, checksum, and optional signature
are uploaded first. `.complete` appears only when the copy is usable. A local
destination follows the same order, with an explicit storage synchronization
before and after publishing that marker. If a network, storage, or removal
failure occurs, Backfort may leave orphan files, but they are not considered a
completed backup because removal deletes `.complete` first.

## Diagnose storage before a run

```bash
sudo backfort.sh -c /etc/backfort/config.yaml doctor
sudo backfort.sh -c /etc/backfort/config.yaml --dry-run run
```

`doctor` is strict: it checks every configured destination. A normal `run`
tries destinations independently, which can result in exit code `1` when an
optional copy fails after another copy succeeds.

See [Retention, Pins and Deletion](Retention-Pins-and-Deletion) for safe
removal of local and cloud copies.
