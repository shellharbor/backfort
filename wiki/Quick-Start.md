# Quick Start

This guide makes one complete local backup of `/etc/nginx` and `/var/www`.
Change every path and name before using it in production.

## 1. Install prerequisites

Backfort needs Linux, Bash 4.3+, GNU userland, and Mike Farah `yq` v4. On
Debian or Ubuntu, install the base utilities:

```bash
sudo apt-get update
sudo apt-get install --yes bash coreutils findutils gzip tar util-linux
```

Install Mike Farah `yq` v4 from its official release or package source. The
Python package also named `yq` is not compatible.

## 2. Install Backfort and the initial config

```bash
sudo install -d -m 0755 /opt/backfort /etc/backfort
sudo install -m 0755 backfort.sh /opt/backfort/backfort.sh
sudo install -m 0640 config.example.yaml /etc/backfort/config.yaml
sudoedit /etc/backfort/config.yaml
```

Start with this minimal job:

```yaml
version: 1
settings:
  host_id: web-01
  state_directory: /var/lib/backfort
  temp_directory: /var/tmp/backfort
  lock_file: /run/backfort.lock
  min_free_mb: 512

destinations:
  - name: local
    type: local
    path: /var/backups/backfort

jobs:
  - name: web-files
    source:
      type: files
      paths: [/etc/nginx, /var/www]
      exclude: ["*.log", "*/cache/*"]
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 7, keep_daily: 7, keep_weekly: 4, keep_monthly: 6}
```

## 3. Validate before writing data

`doctor` validates configuration, source paths, storage locations, configured
tools, and environment-variable references. A dry run plans the normal backup
without creating a bundle.

```bash
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml doctor
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml --dry-run run
```

Fix every error before continuing. In particular, do not point a destination,
state directory, or temporary directory inside a source directory.

## 4. Create and inspect a backup

```bash
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml run
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml list --job web-files
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml status --job web-files
```

The `list` output contains the backup ID. `status` shows the newest completed
copy per destination.

## 5. Verify and restore into a safe directory

```bash
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml \
  verify latest --job web-files --full

sudo install -d -m 0700 /srv/recovery/web-files
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml \
  restore latest --job web-files --to /srv/recovery/web-files
```

Absolute source paths are preserved below the restore root. For example,
`/etc/nginx` becomes `/srv/recovery/web-files/etc/nginx`. Inspect that restored
tree before using it in a recovery. See [Restore and Verification](Restore-and-Verification)
for a full drill.
