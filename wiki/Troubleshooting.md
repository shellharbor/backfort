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
| Volume snapshot fails | The Docker daemon, project, volume and trusted helper image must be available to the account that runs Backfort. |
| Database dump fails | Verify service name, engine, database, user and password environment variable. Ensure the necessary client is in the database container. |
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
