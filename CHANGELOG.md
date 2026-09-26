# Changelog

All notable changes are documented here. Backfort follows semantic versioning
once a release is tagged.

## Unreleased 0.3.0

- Added `quick PATH ... --to DESTINATION` for immediate file and directory
  backups without a prewritten YAML job, including excludes, local/rclone copy
  policy, and a saved non-secret recovery configuration.
- Added the explicit `delete` date-range purge for complete unpinned copies on
  local and rclone destinations. It requires UTC `--since`/`--until` dates and
  `--confirm` after a dry-run plan, and reuses atomic remote deletion rules.
- Added `quick-compose PROJECT_DIR --to DESTINATION` for immediate explicit
  Compose project backups to local or rclone destinations. It supports selected
  volumes and bind mounts plus PostgreSQL, MySQL, and MariaDB logical SQL dumps;
  PostgreSQL quick dumps use the new optional `format: sql` adapter setting.
- Added optional `retention.max_age_days` for automatic hard expiry of
  unpinned backups, independent of GFS counts.
- Added a unified notification event layer for Telegram, ntfy, webhooks, and
  local SMTP transports, including recovery transitions, antiflood state,
  optional daily digests, redaction, and non-fatal delivery warnings.
- Added strict per-channel notification templates with actionable restore
  hints, a fixed safe placeholder whitelist, Telegram value escaping, and
  bounded UTF-8-safe message rendering.
- Added terminal-only `restore --pick` for selecting a completed backup
  version before running the existing safe restore path.
- Added per-destination `pin` and `unpin` markers so migration recovery points
  stay outside GFS rotation without consuming retention slots.
- Added `diff ID1 ID2` for read-only comparison of two indexed backup
  manifests, including text and JSON output.
- Added the read-only `watchdog` dead man's switch. It checks the newest valid
  completed backup copy across each selected job's destinations and returns a
  non-zero status when a backup is missing or too old.
- Added the `docker_compose` source with explicit Compose files, named volumes
  and bind mounts.
- Added PostgreSQL, MySQL and MariaDB logical dumps, plus native MS SQL and
  Oracle export artifact adapters.
- Added a Compose smoke test with a hermetic fake Docker boundary.
- Added a recovery guide for staged Compose restores; automatic in-place
  restores remain intentionally unsupported.
- Added multi-recipient age encryption while retaining the legacy single
  recipient setting.
- Added optional Minisign detached payload signatures, verified before the
  checksum during verification and restore.
- Hardened symmetric GPG encryption with iterated SHA-512 S2K parameters.

## 0.2.0

- Added rclone destinations with atomic-by-marker publication, remote listing,
  verification, restore and conservative prune support.
- Added `success.min_copies` so jobs can require multiple completed copies.
- Fixed `run` so an unavailable local destination produces a partial result
  after other independent destinations have been attempted.
- Kept `doctor` strict: it validates every configured destination before a
  scheduled backup is trusted.
- Added Ubuntu CI for Bash syntax, ShellCheck and the integration smoke test.
- Added the Docker Compose recovery contract that guides the upcoming remote
  storage and database adapters.

## 0.1.0

- Initial public release: file sources, local destinations, atomic completed
  bundles, verification, safe restore and GFS-style retention.
