# Backfort project context

Backfort is a one-shot Bash backup and recovery tool for Linux. Its public
configuration is YAML and the executable is `backfort.sh`.

## Current scope

- Full file and Docker Compose backups to local or rclone destinations.
- `quick PATH ... --to DESTINATION` makes an immediate file or directory
  backup without a saved YAML job. It supports tar excludes, optional symlink
  following, local/rclone copies, and a non-secret recovery config saved under
  the protected state directory.
- `quick-compose` makes a one-off explicit Compose project backup without a
  saved YAML job. It accepts local and rclone destinations, selected volumes
  and bind mounts, plus PostgreSQL/MySQL/MariaDB SQL dumps. It saves a
  non-secret recovery configuration under the protected state directory and
  reuses the normal atomic publication pipeline.
- Atomic publication: a backup copy is usable only after its `.complete`
  marker is published.
- A completed bundle has payload, metadata, checksum and `.complete`; optional
  `.minisig` authenticates the payload and optional `.pinned` stores a pin UTC
  timestamp plus a non-secret reason.
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
  key material into configuration, test fixtures, or log output.

## Verification

Run syntax checks, ShellCheck, and the individual scripts in `tests/`.
GitHub Actions runs the full test set on Ubuntu with Mike Farah yq v4.

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
