# Changelog

All notable changes are documented here. Backfort follows semantic versioning
once a release is tagged.

## Unreleased 0.5.0

- Added `retention.min_keep`, a positive per-destination recovery floor that
  defaults to one newest ordinary completed copy. GFS rotation and
  `max_age_days` never remove that floor.
- Hardened local bundle durability: Backfort synchronizes required artifacts
  before publishing `.complete`, then synchronizes the marker and destination
  directory. Local deletion now removes `.complete` before payload evidence.
- Moved symmetric-GPG and recovery-key passphrases from Bash here-strings to a
  pipe-backed file descriptor so older Bash versions do not materialize them
  in a temporary file.

- Added per-file SHA-256 values for regular archive files in new manifests.
  Full verification and normal restore recompute them from the tar stream,
  detecting changed archive content even when an outer payload checksum was
  replaced. Older manifests remain compatible with their existing
  archive-level validation.
- Added asymmetric GPG encryption with one or more exact public-key
  fingerprints. A backup writer needs only public keys; recovery uses the
  matching private key on a separate host. Symmetric GPG remains supported,
  and an optional recovery-only private-key passphrase environment variable
  supports unattended full verification and restore.
- Added hermetic GPG configuration coverage and an integration test that proves
  a public-key-only writer can create a backup restored by a separate private
  keyring.
- Added `restore-compose` for verified, staged Docker Compose recovery. It
  prints recovery actions by default and can import PostgreSQL, MySQL, and
  MariaDB logical dumps into an existing running target project only with
  explicit `--project-dir --apply --confirm` safeguards. It never deploys
  files, restores volumes, starts services, applies PostgreSQL global roles, or
  guesses MS SQL/Oracle vendor recovery.
- Added optional Prometheus node_exporter textfile metrics for each saved job,
  with atomically replaced per-job files, stable low-cardinality labels, run
  status/duration/size/copy gauges, strict readiness checks, and non-fatal
  runtime write warnings.
- Added a GitHub Documentation workflow that checks local Markdown links across
  the README, Wiki sources, examples, and community files, plus whitespace in
  changed files.
  CI and CodeQL now support manual dispatch and concurrency control; Dependabot
  groups weekly GitHub Actions updates into reviewable pull requests.
- Added GitHub Actions coverage for Bash 4.3 syntax compatibility, CodeQL,
  OpenSSF Scorecard, tag-to-version release metadata validation, and weekly
  GitHub Actions dependency updates through Dependabot.
- Added safe per-job `hooks.pre` and `hooks.post` lifecycle scripts with
  literal argument arrays, strict ownership/mode checks, a scrubbed hook
  environment, dry-run planning, and best-effort cleanup after interrupted
  backup work.
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

### Fixed

- Made `run` turn per-job preflight errors into observable operational failures:
  it writes the failed Prometheus result when the collector is usable, emits the
  standard `failure` event with `stage=preflight`, and continues independent
  selected jobs. Compose database password environment variables are now
  checked before any dump command starts; `doctor` retains its strict code-2
  validation behavior. A broken Prometheus collector cannot receive a metric,
  but now sends the same preflight alert without starting backup work.
- Scoped automatic discovery in shared local and rclone destinations to the
  configured `host_id`. `list`, `status`, `latest`, interactive picking,
  watchdog, retention, and date-range deletion now ignore other hosts' IDs
  before validation, so a foreign malformed object cannot block maintenance or
  a foreign fresh copy cannot hide a stale host.
- Made `quick` and `quick-compose` include the local hostname in their
  generated host IDs; `BACKFORT_QUICK_HOST_ID` provides a deliberate override
  for environments where hostnames are not unique.
- Made temporary-workspace creation an explicit operational failure rather than
  allowing later paths to be formed from an empty directory. Added real Bash
  4.3 runtime coverage for empty argument arrays, not only a syntax check.
- Kept Compose volume helpers networkless and read-only while adding only
  `DAC_READ_SEARCH`, allowing snapshots of application-owned `0700` data
  without restoring broad container capabilities.
- Made full verification and staged restore stream a materialized rclone
  payload from its verified local temporary file instead of incorrectly passing
  that local path back to `rclone cat`.
- Restored successful preflight completion for ordinary file sources after all
  destination safety checks pass.
- Made the executable mode of the CLI and test adapters a CI-enforced release
  invariant, so a fresh Linux checkout can invoke them directly.
- Replaced unsupported `if` expressions in generated JSON with `yq` v4
  compatible filters for Telegram topic IDs and `list --json` pin metadata.
- Made the fake `age` adapter model streaming decryption, so the encryption
  smoke test exercises the real restore data path.
- Made fixture metadata with a `.json` extension valid JSON, matching the
  production bundle format.

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
