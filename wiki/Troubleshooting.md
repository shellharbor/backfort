# Troubleshooting

Start every diagnosis with a non-writing configuration and environment check:

```bash
backfort.sh -c /etc/backfort/config.yaml doctor
backfort.sh -c /etc/backfort/config.yaml --dry-run run
```

The most useful information is emitted as structured log lines. Keep the log
from the failed run, but remove any unrelated system secrets before sharing it.

## Common failures

| Symptom | Likely cause and resolution |
| --- | --- |
| `yq` rejected or configuration parsing fails | Backfort requires Mike Farah `yq` v4. The unrelated Python package named `yq` is not compatible. |
| `rclone` destination unavailable | Check the remote with `rclone lsd REMOTE:` under the same service account; confirm the bucket/path and rclone credential file. |
| A backup is partial | One or more destinations failed but another copy succeeded. Read the destination lines, fix the failed copy, then run again. |
| No backup appears in `list` | Only versions with `.complete` are listed. An interrupted upload is intentionally hidden and must be recreated. |
| `another-run-is-active` | A mutating Backfort command owns the global lock. Let it finish; do not delete lock files to force a second writer. |
| `prometheus-textfile-directory-not-usable` | Create the configured textfile directory, make it writable by the Backfort execution account, readable by node_exporter, and ensure it is not a symlink. Run `doctor` after correcting it. |
| `kind=metrics` warning after a run | The backup result is unchanged, but Prometheus was not updated. Restore the collector directory and permissions, then run Backfort again to publish fresh gauges. |
| `stage=preflight` failure alert or `.prom` with `exit_code 3` | A selected job could not start safely (for example a source disappeared, Docker/Compose is unavailable, or a database password variable is empty). Read the matching structured log line, repair that job, then run it again. Other selected jobs are still attempted. |
| Missing Compose database `password_env` | Put the secret value—not a YAML literal—in the named service-account environment, credential file, or secret manager. `doctor` exits `2`; `run` records that individual job as a preflight failure without starting a dump. |
| Volume snapshot fails | The Docker daemon, project, volume and trusted helper image must be available to the account that runs Backfort. Ensure the pinned helper contains `tar` and runs it as root; Backfort supplies only the read/search capability needed for application-owned `0700` directories. |
| Database dump fails | Verify service name, engine, database, user and password environment variable. Ensure the necessary client is in the database container. |
| `kind=compose-exec ... message=timed-out` | The configured `command_timeout_seconds` elapsed. Check the Docker daemon and database client, then increase the setting only after measuring a healthy large dump. |
| `kind=hook ... message=timed-out` | The hook exceeded its `timeout_seconds`. Run its cleanup action manually if needed, make the post hook idempotent, then fix or resize the bound. |
| `unsupported-entries-skipped` during pack | Backfort preserved the usable portion of the source but omitted FIFO/device entries or names unsafe for a portable manifest. Replace or explicitly exclude those entries if they are required data. |
| Restore refuses a target | Restore into a new or empty explicit directory; inspect a staging restore before replacing live data. |

## Diagnose a destination and a version

```bash
# Show completed versions and the latest completed copy per destination.
backfort.sh -c /etc/backfort/config.yaml list --job important-files
backfort.sh -c /etc/backfort/config.yaml status --job important-files

# Test a specific remote copy before needing it.
backfort.sh -c /etc/backfort/config.yaml verify BACKUP_ID --from s3-offsite --full

# Compare the last known-good backup with a newer version.
backfort.sh -c /etc/backfort/config.yaml diff OLDER_ID NEWER_ID --from s3-offsite --json
```

## Exit codes for automation

| Exit code | Meaning |
| ---: | --- |
| `0` | Complete success. |
| `1` | Partial result: some destinations succeeded and some failed. |
| `2` | Invalid CLI, configuration, dependency or environment. |
| `3` | Operational failure, including a copy policy that was not met. |

Treat codes `1`, `2`, and `3` as actionable in monitoring. For a shell-based
scheduled job, preserve the command exit status instead of masking it with a
trailing command that succeeds.

## Before asking for help

Collect the Backfort version, operating-system version, command invoked,
redacted output from `doctor`, and relevant structured log lines. State whether
the target is local storage or a named rclone remote. Never include passwords,
encryption identities, Telegram tokens, or cloud access keys.

## Maintainers: release checks

Before publishing a release, run the repository checks on a fresh Linux
checkout. The CLI and its test adapters must retain their executable bits, and
the full suite must run with Mike Farah `yq` v4—the only supported YAML
implementation. Keep the version reported by `backfort.sh --version`, the
release-ready Changelog heading, and the eventual Git tag aligned. The
`Release metadata` GitHub workflow rejects a `vX.Y.Z` tag unless the CLI
reports the same non-development version and `CHANGELOG.md` has an exact
`## X.Y.Z` heading. Include a
full verification and staged restore of an rclone copy: it proves that a
downloaded remote payload is both checked and streamed as the local verified
artifact.
