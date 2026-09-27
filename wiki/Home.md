# Backfort Wiki

Backfort is a one-shot Bash backup and recovery tool for Linux. It creates a
complete backup, verifies enough of it to publish safely, writes independent
copies to local or rclone storage, and exits. It is intentionally not a daemon:
cron or a systemd timer decides when it runs.

Backfort protects ordinary directories, Docker Compose projects, selected
volumes and bind mounts, and database dumps. Every completed copy consists of
the payload, manifest, checksum, and a final `.complete` marker. A copy without
that marker is never listed, restored, pruned, or selected as healthy.

Examples use `backfort.sh` as the command name. From an installed production
layout, use `sudo /opt/backfort/backfort.sh`; from a cloned checkout, use
`./backfort.sh`.

## Start here

1. [Quick Start](Quick-Start) — install and make the first local backup.
2. [Configuration](Configuration) — build a durable YAML backup plan.
3. [Destinations and S3](Destinations-and-S3) — add S3-compatible offsite
   storage through rclone.
4. [Restore and Verification](Restore-and-Verification) — prove a backup is
   usable before an incident.
5. [Monitoring and Metrics](Monitoring-and-Metrics) — expose run outcomes to
   Prometheus and add independent freshness checks.

For immediate work without preparing YAML first, use
[Quick Backups](Quick-Backups). For application stacks, read
[Docker Compose and Databases](Docker-Compose-and-Databases) before backing up
a database volume.

Moving an application to another host? Follow the explicit
[Compose Migration](Compose-Migration) runbook rather than treating a volume
archive as an automatic in-place server transfer.

## Project community

The repository also maintains its GitHub contribution and safety documents:
[Contributing](https://github.com/shellharbor/backfort/blob/main/CONTRIBUTING.md),
[Security policy](https://github.com/shellharbor/backfort/blob/main/SECURITY.md),
[Code of Conduct](https://github.com/shellharbor/backfort/blob/main/CODE_OF_CONDUCT.md),
and [Support](https://github.com/shellharbor/backfort/blob/main/SUPPORT.md).
Never place a vulnerability report or secret in a public issue.

## Repository automation

Every push and pull request runs the Linux regression suite, ShellCheck, YAML
example validation, and Bash 4.3 syntax **and runtime** gates. The suite also
covers shared-destination host isolation, a controlled temporary-workspace
failure, archive resilience for special files and unusual names, and metadata
fidelity for ACLs, extended attributes, sparse files and ownership. A separate Documentation
workflow checks local Markdown links across the README, Wiki sources, examples,
and community documents, plus whitespace in changed files. CodeQL reviews
GitHub Actions workflow definitions;
OpenSSF Scorecard publishes supply-chain findings; Dependabot proposes grouped
weekly GitHub Actions updates. A `vX.Y.Z` tag is accepted only when the CLI
version and the matching Changelog heading are release-ready. The repository
README links to the live workflow results.

The source-control baseline keeps tracked text in LF form so the Bash CLI works
the same from Windows and Linux checkouts. Local IDE metadata such as `.idea/`
is deliberately ignored rather than shared as project configuration.

## The safety model

- Source paths and destination paths are explicit. Backfort never guesses what
  to include.
- Credentials stay outside YAML. A configuration contains environment variable
  names, never passwords, API tokens, or private keys.
- Remote publishing uses `rclone copyto`/`moveto`, never `sync`.
- A backup is only committed after its payload, metadata, and checksum are
  present. Local storage synchronizes those artifacts before `.complete`, then
  synchronizes the commit marker; deletion removes the marker first.
- A stable, unique `host_id` scopes automatic discovery. Hosts can share one
  bucket/path without listing, retaining, deleting, or trusting one another's
  backups by accident.
- Restore always targets a new or empty directory. Backfort will not overwrite
  the original production path.
- Retention, date-range deletion, pins, and ordinary backup creation share a
  non-blocking lock.

## Typical production layout

```text
/opt/backfort/backfort.sh             executable
/etc/backfort/config.yaml             root-owned backup plan
/var/lib/backfort/                    state and notification state
/var/tmp/backfort/                    transient working data
/var/backups/backfort/                local recovery copy
S3 bucket / cloud remote              independent offsite copy
```

The usual production sequence is `doctor`, a dry run, a real run, then a full
verification and a staged restore drill:

```bash
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml doctor
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml --dry-run run
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml run
sudo /opt/backfort/backfort.sh -c /etc/backfort/config.yaml \
  verify latest --job important-files --full
```

Continue with [Quick Start](Quick-Start).
