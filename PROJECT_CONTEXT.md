# Backfort project context

Backfort is a one-shot Bash backup and recovery tool for Linux. Its public
configuration is YAML and the executable is `backfort.sh`.

## Current scope

- Full file and Docker Compose backups to local or rclone destinations.
- Encryption supports multi-recipient age, hardened symmetric GPG, and
  asymmetric GPG. An asymmetric writer imports only verified recipient public
  keys and encrypts to exact 40- or 64-hex primary fingerprints; the private
  key stays on a separate recovery host. An optional identity-passphrase
  environment variable is read only during full verification or restore.
- Saved jobs may declare executable `hooks.pre` and `hooks.post` lifecycle
  scripts for application quiescing and cleanup. Hooks use literal YAML
  argument arrays, run in a scrubbed non-secret environment, and must be
  owned by the Backfort execution account and not writable by group or others.
  A post hook is attempted after a completed pre hook even when the backup
  fails; hooks remain responsible for idempotent cleanup after SIGKILL or a
  host failure.
- `quick PATH ... --to DESTINATION` makes an immediate file or directory
  backup without a saved YAML job. It supports tar excludes, optional symlink
  following, local/rclone copies, and a non-secret recovery config saved under
  the protected state directory.
- `quick-compose` makes a one-off explicit Compose project backup without a
  saved YAML job. It accepts local and rclone destinations, selected volumes
  and bind mounts, plus PostgreSQL/MySQL/MariaDB SQL dumps. It saves a
  non-secret recovery configuration under the protected state directory and
  reuses the normal atomic publication pipeline. A server-to-server migration
  uses this as the verified source-side snapshot and a deliberate staged target
  restore; Backfort does not automatically connect to, deploy on, or cut over
  a target server.
- `restore-compose` stages a verified Compose backup and emits an inventory of
  project files, bind mounts, volume archives, and database artifacts. With an
  explicit target project plus `--apply --confirm`, it imports PostgreSQL,
  MySQL, and MariaDB logical dumps only after verifying the target Compose
  files and running database services. It does not copy project files, restore
  volumes, start services, apply PostgreSQL global roles, or automate MS SQL
  and Oracle recovery.
- Atomic publication: a backup copy is usable only after its `.complete`
  marker is published.
- A completed bundle has payload, metadata, checksum and `.complete`; optional
  `.minisig` authenticates the payload and optional `.pinned` stores a pin UTC
  timestamp plus a non-secret reason.
- New manifests declare `file_hash_algorithm: sha256` and record a SHA-256
  value for each regular archive file. Full verification and restore recompute
  those values from the archived bytes; legacy manifests without the marker
  retain their established archive-level verification path.
- `list`, `status`, `verify`, `restore`, `prune`, `delete`, and `watchdog` operate only
  on complete, structurally valid bundles.
- `diff ID1 ID2` compares the indexed manifest entries of two completed copies
  without extracting user data. It detects path additions/removals and changes
  to type, size, or mtime; it is not a content hash comparison.
- `pin` and `unpin` manage an optional per-destination `.pinned` marker for a
  completed backup. Pinned copies are outside GFS rotation and `max_age_days`
  expiry, never consume retention slots, and have an operator-managed storage
  lifetime. Unpinned copies may use positive `retention.max_age_days` as a
  hard expiry that overrides the ordinary GFS keep set during `prune`.
- `delete --job NAME --since YYYY-MM-DD --until YYYY-MM-DD` removes complete,
  unpinned backup copies in one inclusive UTC date range. It requires either
  `--dry-run` or explicit `--confirm`; without `--from DESTINATION` it applies
  to every destination of the job, including rclone remotes.
- `restore --pick` is an explicit interactive terminal-only selector for a
  completed backup version. It resolves an ID and destination before entering
  the ordinary restore path; non-TTY calls fail instead of waiting for input.
- `watchdog` is a read-only dead man's switch. It finds the newest valid copy
  for each selected job using the UTC timestamp in the backup ID and returns
  exit code `3` when a job is stale or has no completed backup.
- Optional notifications use one internal event contract for Telegram, ntfy,
  webhooks, and a local sendmail-compatible SMTP transport. Events include
  backup result transitions, watchdog failures, restore result, and completed
  prune activity. Delivery failures only warn and never change command exits.
- Optional Prometheus node_exporter textfile metrics are atomically replaced
  after each non-dry-run saved job. The per-job gauges carry only stable host
  and job labels plus numeric run, duration, payload-size, and copy-count
  state; metrics write failures warn without changing a backup result.
- Per-job notification state records `ok` or `bad` atomically. Recovery is a
  transition from bad to successful; failure, partial, and watchdog alerts use
  per-channel antiflood state. An opt-in daily digest is stored under the
  state directory and flushed by the next Backfort event.
- Text notification templates use a fixed, non-secret placeholder whitelist.
  They are validated before command execution and rendered with literal Bash
  substitutions only—never `eval`, `bash -c`, or template-driven indirection.
  Values are redacted before channel-specific escaping; Telegram may use only
  trusted literal HTML from the root-owned configuration.

## Safety conventions

- Configuration validation is strict, including unknown keys and job/destination
  references.
- Backup creation and pruning use a shared non-blocking lock. `watchdog` does
  not take that lock so monitoring is not delayed by a running backup.
- Logs are structured `key=value` records. Do not put credentials or private
  key material into configuration, test fixtures, or log output. GPG public
  recipient fingerprints are not secrets, but private keys and their
  passphrases never belong on a backup writer.

## Verification

Run syntax checks, ShellCheck, and the individual scripts in `tests/`.
`tests/file-hashes.sh` proves that new manifests hash regular files, full
verification rejects a changed archived file even after its outer checksum is
rewritten, and legacy manifests remain verifiable.
`tests/metrics.sh` covers the Prometheus output contract, partial results,
strict schema validation, `doctor` readiness, and a non-fatal post-run metrics
write failure.
`tests/gpg-asymmetric.sh` creates temporary GnuPG keyrings to prove that a
writer with only a recipient public key can create a backup recovered by the
separate private keyring.
GitHub Actions runs the full test set on Ubuntu with Mike Farah yq v4 and a
Bash 4.3 syntax gate. CodeQL scans workflow definitions; OpenSSF Scorecard
publishes supply-chain findings; a `v*` tag must match the release-ready CLI
version and Changelog heading; a Documentation workflow checks local Markdown
links and whitespace; Dependabot proposes grouped weekly GitHub Actions
updates.

## CLI

`diff ID1 ID2 [--from DEST] [--json]` compares manifest metadata only. A file
that changes without a different size or mtime is not detected; use
`verify --full` or a recovery drill when that distinction matters.

`pin BACKUP_ID [--from DEST] [--reason TEXT]` protects completed copies from
prune. Without `--from`, it acts on every destination carrying that completed
ID. `unpin BACKUP_ID [--from DEST]` removes the marker. Pins use the same
non-blocking global lock as other mutating commands.

`restore --pick --to DIRECTORY [--job NAME] [--from DEST]` renders completed
versions and asks an operator to choose one. It is unavailable to cron, pipes,
and systemd because both stdin and stdout must be TTYs.

`restore-compose BACKUP_ID --to DIRECTORY [--project-dir TARGET --apply
--confirm]` is the staged Docker Compose recovery helper. Normal use only
stages and prints the recovery inventory. The optional apply path is a
deliberate logical database import boundary, not a deployment command: it
requires an existing target Compose project, its database containers running,
and both explicit flags. It supports PostgreSQL, MySQL, and MariaDB; a job with
MS SQL or Oracle must use a vendor-native manual recovery procedure.

`delete --job NAME --since YYYY-MM-DD --until YYYY-MM-DD [--from DESTINATION]`
is the manual period purge. `--until` includes the full UTC calendar day;
actual deletion additionally requires `--confirm`. Pinned copies are retained,
so a pin must be deliberately removed before that copy can be purged.

`quick-compose PROJECT_DIR --to DESTINATION [OPTIONS]` is the emergency
Compose interface. `DESTINATION` is either an absolute local path or
`rclone:REMOTE:PATH`; repeat it for independent cloud copies. Database specs
are `NAME:SERVICE:ENGINE:USER:PASSWORD_ENV:DB1,DB2`, where the supported
quick-mode engines are `postgres`, `mysql`, and `mariadb`. PostgreSQL quick
dumps use plain `.sql`; MS SQL and Oracle continue to use their native formats
through regular YAML jobs. The generated recovery config is saved under
`$XDG_STATE_HOME/backfort/quick-compose/` (or `$HOME/.local/state/backfort/`)
unless `--state-directory` selects another protected location.

`quick PATH [PATH ...] --to DESTINATION [OPTIONS]` is the corresponding
emergency interface for ordinary files and directories. It accepts repeated
`--exclude` patterns, `--follow-symlinks`, and repeated local or
`rclone:REMOTE:PATH` destinations. Its generated recovery config is saved in
`$XDG_STATE_HOME/backfort/quick/` (or `$HOME/.local/state/backfort/quick/`).
