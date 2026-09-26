# Support

Backfort is a recovery tool, so support requests should preserve enough context
to diagnose a problem without exposing the data being protected.

## Start with the documentation

- [Quick Start](wiki/Quick-Start.md)
- [Configuration](wiki/Configuration.md)
- [Destinations and S3](wiki/Destinations-and-S3.md)
- [Docker Compose and Databases](wiki/Docker-Compose-and-Databases.md)
- [Restore and Verification](wiki/Restore-and-Verification.md)
- [Troubleshooting](wiki/Troubleshooting.md)

For a configuration or environment problem, run these safe diagnostics first:

```bash
backfort.sh -c /etc/backfort/config.yaml doctor
backfort.sh -c /etc/backfort/config.yaml --dry-run run
```

## Asking for help

Use a GitHub issue for a reproducible bug, documentation problem, or focused
feature idea. Include:

- Backfort version or commit and Linux distribution;
- the command that failed, with sensitive values removed;
- the smallest safe configuration fragment;
- relevant structured log lines, redacted;
- whether the destination is local or a named rclone remote;
- what you expected and what actually happened.

Do **not** include passwords, API tokens, private keys, age identities, GPG
passphrases, database dumps, bucket names, full backup IDs, or customer data.
For a suspected vulnerability, use [SECURITY.md](SECURITY.md), not an issue.

## What support can and cannot provide

The project can help clarify documented behavior and investigate reproducible
defects. It cannot safely operate your production environment, access your
storage account, recover lost credentials, or guarantee a recovery outcome.
Always test restores in an isolated environment before relying on a backup plan.

Support is best-effort and has no service-level agreement. For a production
incident, prioritize your established incident process and a known-good,
verified recovery procedure.
