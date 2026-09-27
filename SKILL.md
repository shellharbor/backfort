---
name: backfort
description: Implement, review, test, or document Backfort's Linux backup and recovery workflow, including YAML configuration, lifecycle hooks, local and rclone destinations, Docker Compose backups and recovery assistance, databases, retention, notifications, and Prometheus textfile metrics. Use for changes inside the Backfort repository; do not use for generic backup advice unrelated to this codebase.
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
- `.gitattributes` — LF normalization for portable shell, YAML and Markdown;
- `README.md` and `wiki/` — public operating documentation;
- `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, and `SUPPORT.md` —
  GitHub community, disclosure, and contribution contracts;
- `PROJECT_CONTEXT.md` and `CHANGELOG.md` — current scope and release notes.

Keep local editor metadata such as `.idea/` outside version control. It is
ignored workspace state, not a project artifact.

## Preserve the recovery contract

- A local backup copy is recoverable only after its payload, metadata, checksum
  and optional Minisign signature are synchronized, then its `.complete`
  marker and destination directory are synchronized. Local and rclone removal
  must remove `.complete` first; harmless orphan objects are preferable to a
  partial bundle that appears recoverable. `.pinned` markers retain their
  documented role.
- Treat `settings.host_id` as the boundary for every automatic discovery path.
  `list`, `status`, `latest`, `restore --pick`, `watchdog`, `prune`, and
  date-range `delete` must ignore another host's IDs before validating or
  deleting them. A full explicit ID may support a deliberate cross-host
  recovery, but must not weaken automated isolation.
- Never make `list`, `status`, `verify`, `restore`, `prune`, `delete`, `diff`,
  or `watchdog` treat an incomplete or malformed bundle as valid.
- New manifests record a SHA-256 value for every regular archive file. Keep
  `verify --full` and normal restore recomputing and comparing those hashes
  before extraction; retain compatibility with legacy manifests that predate
  the explicit `file_hash_algorithm` marker.
- Preserve recovery fidelity for supported regular files: GNU tar backups and
  restores carry numeric owners, ACLs, extended attributes and sparse extents.
  Never reintroduce `--no-same-owner` into a root-capable staged restore. A
  live file changing during capture may be omitted with GNU tar's documented
  warning, but must not invalidate the rest of the version. FIFO/device nodes
  and names unsafe for the portable manifest are intentionally omitted rather
  than silently restored or allowed to make a whole backup fail.
- Keep normal restore staged: it requires a new or empty explicit directory.
  Do not introduce in-place restore or a force-overwrite path casually.
- `success.min_copies` determines success across independent destinations. A
  partial copy result is distinct from a failed copy policy and must retain its
  documented exit code.
- Retention, pins and date-range deletion protect completed bundles.
  `retention.min_keep` defaults to one and protects the newest ordinary copies
  from both GFS rotation and `max_age_days`. Pinned copies remain outside GFS
  retention and age expiry; deletion needs its existing explicit
  dry-run/confirmation safety boundary.
- Docker Compose backups are explicit. Never infer files, volumes, bind mounts
  or database services from an image or a Compose file. Database volumes do not
  replace logical engine dumps.
- Compose volume helpers remain networkless with a read-only root filesystem
  and source mount. Keep the capability set minimal: `DAC_READ_SEARCH` is the
  only added capability, so app-owned `0700` data can be read without granting
  write or broader privilege. Do not use an unguarded `mktemp`: a workspace
  creation failure must stop the command before any later path is formed.
- `restore-compose` is staged by default. Its optional database import requires
  an explicit target project and both `--apply --confirm`; it must not deploy
  project files, create or restore volumes, start services, apply PostgreSQL
  global roles, or guess MS SQL/Oracle recovery.

## Keep secrets and shell boundaries safe

- Configuration stores environment-variable *names*, never secret values.
  Keep credentials, identities, keys and tokens out of YAML, examples, tests,
  logs, generated recovery configuration and notification text.
- Asymmetric GPG uses exact 40- or 64-hex public-key fingerprints supplied by
  environment variables. The backup writer may import only verified public
  keys; private keys and any `identity_password_env` value remain on a separate
  recovery host. Do not weaken the no-auto-retrieve or exact-fingerprint
  recipient boundary.
- Symmetric GPG and passphrase-protected recovery keys pass their secret through
  a pipe-backed file descriptor. Do not reintroduce a Bash here-string, which
  may materialize the secret in a temporary file on older Bash versions.
- Validate paths, identifiers, YAML keys, dates, destination names and template
  placeholders at the boundary. Preserve the existing strict unknown-key checks.
- Do not use `eval`, template-driven shell execution, or user-controlled
  `bash -c`/`sh -c`. Quote every shell expansion and retain the existing
  allowlist-based command construction.
- Hooks are executable paths with literal argument arrays, never shell command
  strings. Preserve their ownership/mode validation, scrubbed environment, and
  idempotent post-cleanup contract; do not pass Backfort secrets into hooks.
  Hook `timeout_seconds` is bounded, and a timed-out pre hook must still invoke
  post cleanup.
- Compose `command_timeout_seconds` bounds Docker/Compose preflight, helper,
  copy, exec and dump calls. Do not add an unbounded command path around a
  database dump or restore import.
- rclone publishing uses individual object operations, never a broad `sync`.
  Remote deletion must preserve the commit-marker ordering that prevents a
  partial deletion from appearing recoverable.
- A command's YAML plan and rclone object index are immutable read snapshots:
  cache repeated `cfg` and remote existence reads, but start a new command
  after an out-of-band config or remote change. Do not trade the staged
  manifest/checksum/verification pipeline for speculative streaming.
- Notification delivery is non-fatal. Preserve redaction, bounded rendering,
  per-channel antiflood behavior and the fixed template placeholder whitelist.
  Digest webhooks carry their own `digest` context, Telegram retries rejected
  HTML as plain text once, and authenticated SMTP must use STARTTLS or implicit
  TLS—never a cleartext-auth fallback.
- A persistent `run` isolates each selected job's preflight. A preflight error
  must become that job's code-3 result with `stage=preflight`, zero-valued
  Prometheus copy/payload gauges, and the standard failure event while other
  selected jobs continue. Keep `doctor` strict with its code-2 validation
  semantics. If the Prometheus collector itself is unusable, it cannot receive
  a metric: do not start backup work, but send the preflight failure event.

## Implement by surface

| Change | Inspect and synchronize |
| --- | --- |
| CLI command or option | parser, `usage`, validation, command implementation, focused `tests/*.sh`, README and Wiki command examples |
| YAML schema or default | validator, `config.example.yaml`, relevant `examples/*.yaml`, tests, README and Wiki configuration pages |
| Prometheus metrics | schema and readiness validation, atomic textfile writer, `tests/metrics.sh`, README, `Configuration`, `Monitoring and Metrics`, and troubleshooting Wiki pages |
| Lifecycle hook or timeout | validator and preflight, hook execution and signal cleanup, `tests/hooks.sh`, README, `Configuration`, and `Automation-and-Notifications` Wiki pages |
| GitHub automation or badge | `.github/workflows/`, `.github/dependabot.yml`, README badges, `CHANGELOG.md`, and Wiki maintainer guidance; never add a badge without its real workflow or public service |
| Local/rclone bundle behavior | atomic publish, host-scoped automatic discovery, list/verify/restore/prune/delete behavior, smoke tests, recovery and storage docs |
| Compose or database adapter | Compose validation, fake Docker test, command timeout behavior, recovery instructions, `Docker-Compose-and-Databases`, `Compose-Migration`, and `Restore-and-Verification` Wiki pages |
| Security, encryption, signing or notifications | validation, negative tests, redaction/log review, README and relevant Wiki safety/automation pages |
| GitHub community or disclosure policy | `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, `SUPPORT.md`, README links, and this skill when routing changes |

Use `quick` and `quick-compose` as temporary, non-secret configuration
generators. Their persisted recovery configs belong below the protected state
directory and must remain compatible with ordinary `list`, `verify`, `restore`
and `prune` commands. Their generated host IDs must distinguish writers in a
shared destination: retain the hostname component and the documented
`BACKFORT_QUICK_HOST_ID` override.

## Verify proportionately

Run the focused test for changed behavior first. Before handoff, run the
available repository checks appropriate to the change:

```bash
bash -n backfort.sh tests/*.sh
shellcheck backfort.sh tests/*.sh
bash tests/smoke.sh
```

Run the specialized test when its surface changes: `quick.sh`,
`rclone-smoke.sh`, `compose-smoke.sh`, `restore-compose.sh`,
`crypto-smoke.sh`, `gpg-asymmetric.sh`, `file-hashes.sh`, `watchdog.sh`, `diff.sh`, `pinned.sh`,
`delete-period.sh`, `pick.sh`, `notify.sh`, `hooks.sh`, `metrics.sh`,
`preflight-failure.sh`, `host-scope.sh`, `workspace-failure.sh`,
`archive-resilience.sh`, `fidelity.sh`, `config-cache.sh`, `bash43-runtime.sh`, or
`local-durability.sh`.
For release stabilization, also verify direct execution from a clean Linux
checkout: `backfort.sh` and executable test adapters must retain mode `0755`.
CI provides Mike Farah `yq` v4, GnuPG, ShellCheck and Python on Ubuntu;
generated JSON filters must use syntax supported by that version. If a local
dependency is unavailable, do not install it without authorization; report the
exact skipped check and residual risk. CI also executes a Bash 4.3 runtime
regression, not just parsing; CodeQL and OpenSSF
Scorecard scan the GitHub automation, while the release metadata workflow
requires a `vX.Y.Z` tag to match a non-development CLI version and Changelog
heading.

## Maintain this skill

Review this `SKILL.md` with every project change. Update it in the same change
whenever Backfort's supported scope, CLI, configuration schema, safety model,
test suite, source layout, or documentation routing changes. Synchronize the
relevant `wiki/` pages for every public behavior change, and never claim this
repository-local skill has been globally installed unless the user explicitly
requested that installation.
