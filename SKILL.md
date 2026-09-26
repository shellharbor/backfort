---
name: backfort
description: Implement, review, test, or document Backfort's Linux backup and recovery workflow, including YAML configuration, local and rclone destinations, Docker Compose, databases, recovery, retention, and notifications. Use for changes inside the Backfort repository; do not use for generic backup advice unrelated to this codebase.
metadata:
  short-description: Maintain the Backfort backup tool
---

# Backfort

Backfort is a one-shot Bash backup and recovery tool for Linux. Its public
entry point is `backfort.sh`; YAML is the durable configuration contract.
Scheduled execution belongs to cron or systemd, not to a resident Backfort
daemon.

## Start with the current contract

Read `AGENTS.md`, then the relevant project rules under `.ai/`. Inspect the
affected command parser, configuration validation, implementation and matching
test before proposing an interface change. Treat these files as the maintained
product sources:

- `backfort.sh` — implementation and CLI;
- `config.example.yaml` — complete configuration reference;
- `tests/*.sh` — hermetic executable behavior examples;
- `examples/` — user-adaptable configuration examples;
- `README.md` and `wiki/` — public operating documentation;
- `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, and `SUPPORT.md` —
  GitHub community, disclosure, and contribution contracts;
- `PROJECT_CONTEXT.md` and `CHANGELOG.md` — current scope and release notes.

## Preserve the recovery contract

- A backup copy is recoverable only after its `.complete` marker is published.
  The payload, metadata and checksum must be ready first; optional Minisign
  signatures and `.pinned` markers have their documented roles.
- Never make `list`, `status`, `verify`, `restore`, `prune`, `delete`, `diff`,
  or `watchdog` treat an incomplete or malformed bundle as valid.
- Keep normal restore staged: it requires a new or empty explicit directory.
  Do not introduce in-place restore or a force-overwrite path casually.
- `success.min_copies` determines success across independent destinations. A
  partial copy result is distinct from a failed copy policy and must retain its
  documented exit code.
- Retention, pins and date-range deletion protect completed bundles. Pinned
  copies remain outside GFS retention and `max_age_days`; deletion needs its
  existing explicit dry-run/confirmation safety boundary.
- Docker Compose backups are explicit. Never infer files, volumes, bind mounts
  or database services from an image or a Compose file. Database volumes do not
  replace logical engine dumps.

## Keep secrets and shell boundaries safe

- Configuration stores environment-variable *names*, never secret values.
  Keep credentials, identities, keys and tokens out of YAML, examples, tests,
  logs, generated recovery configuration and notification text.
- Validate paths, identifiers, YAML keys, dates, destination names and template
  placeholders at the boundary. Preserve the existing strict unknown-key checks.
- Do not use `eval`, template-driven shell execution, or user-controlled
  `bash -c`/`sh -c`. Quote every shell expansion and retain the existing
  allowlist-based command construction.
- rclone publishing uses individual object operations, never a broad `sync`.
  Remote deletion must preserve the commit-marker ordering that prevents a
  partial deletion from appearing recoverable.
- Notification delivery is non-fatal. Preserve redaction, bounded rendering,
  per-channel antiflood behavior and the fixed template placeholder whitelist.

## Implement by surface

| Change | Inspect and synchronize |
| --- | --- |
| CLI command or option | parser, `usage`, validation, command implementation, focused `tests/*.sh`, README and Wiki command examples |
| YAML schema or default | validator, `config.example.yaml`, relevant `examples/*.yaml`, tests, README and Wiki configuration pages |
| Local/rclone bundle behavior | atomic publish, list/verify/restore/prune/delete behavior, smoke tests, recovery and storage docs |
| Compose or database adapter | Compose validation, fake Docker test, recovery instructions, `Docker-Compose-and-Databases` and `Restore-and-Verification` Wiki pages |
| Security, encryption, signing or notifications | validation, negative tests, redaction/log review, README and relevant Wiki safety/automation pages |
| GitHub community or disclosure policy | `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `SUPPORT.md`, README links, and this skill when routing changes |

Use `quick` and `quick-compose` as temporary, non-secret configuration
generators. Their persisted recovery configs belong below the protected state
directory and must remain compatible with ordinary `list`, `verify`, `restore`
and `prune` commands.

## Verify proportionately

Run the focused test for changed behavior first. Before handoff, run the
available repository checks appropriate to the change:

```bash
bash -n backfort.sh tests/*.sh
shellcheck backfort.sh tests/*.sh
bash tests/smoke.sh
```

Run the specialized test when its surface changes: `quick.sh`,
`rclone-smoke.sh`, `compose-smoke.sh`, `crypto-smoke.sh`, `watchdog.sh`,
`diff.sh`, `pinned.sh`, `delete-period.sh`, `pick.sh`, or `notify.sh`.
CI provides Mike Farah `yq` v4, ShellCheck and Python on Ubuntu. If a local
dependency is unavailable, do not install it without authorization; report the
exact skipped check and residual risk.

## Maintain this skill

Review this `SKILL.md` with every project change. Update it in the same change
whenever Backfort's supported scope, CLI, configuration schema, safety model,
test suite, source layout, or documentation routing changes. Synchronize the
relevant `wiki/` pages for every public behavior change, and never claim this
repository-local skill has been globally installed unless the user explicitly
requested that installation.
