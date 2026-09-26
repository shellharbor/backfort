#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d)

cleanup() {
  case "$TEST_DIRECTORY" in
    /tmp/*|/var/tmp/*) rm -rf -- "$TEST_DIRECTORY" ;;
  esac
}
trap cleanup EXIT

SOURCE_DIRECTORY="$TEST_DIRECTORY/source"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY"
printf 'watchdog test content\n' >"$SOURCE_DIRECTORY/important.txt"

write_config() {
  local file=$1
  local destination=$2
  cat >"$file" <<EOF
version: 1
settings:
  host_id: watchdog-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$destination"
jobs:
  - name: watchdog
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 1, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF
}

write_two_destination_config() {
  local file=$1
  local primary=$2
  local replica=$3

  write_config "$file" "$primary"
  sed -i "/^jobs:/i\\  - name: replica\n    type: local\n    path: \"$replica\"" "$file"
  sed -i 's/destinations: \[local\]/destinations: [local, replica]/' "$file"
}

make_complete_bundle() {
  local destination=$1
  local backup_id=$2
  local payload="$destination/$backup_id.tar.gz"

  mkdir -p "$destination"
  printf 'test payload\n' >"$payload"
  printf 'checksum is not verified by watchdog\n' >"$destination/$backup_id.sha256"
  cat >"$destination/$backup_id.metadata.json" <<EOF
backup_id: "$backup_id"
job: watchdog
payload_file: "$backup_id.tar.gz"
signing:
  method: none
EOF
  printf '%s\n' "$backup_id" >"$destination/$backup_id.complete"
}

write_config "$CONFIG_FILE" "$BACKUP_DIRECTORY"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" watchdog \
  >"$TEST_DIRECTORY/missing-max-age.stdout" 2>"$TEST_DIRECTORY/missing-max-age.stderr"; then
  printf 'expected watchdog without a threshold to be rejected\n' >&2
  exit 1
else
  MISSING_MAX_AGE_RESULT=$?
fi
[[ $MISSING_MAX_AGE_RESULT -eq 2 ]]
grep -Fq 'watchdog-max-age-required' "$TEST_DIRECTORY/missing-max-age.stderr"

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run

CURRENT_BACKUP_ID=$(basename -- "$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -print -quit)" .complete)
WATCHDOG_OUTPUT=$("$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" watchdog --max-age 1)
grep -Fq "job=watchdog backup_id=$CURRENT_BACKUP_ID" <<<"$WATCHDOG_OUTPUT"

# A held run/prune lock must not delay a read-only watchdog invocation.
exec {LOCK_FD}>"$TEST_DIRECTORY/backfort.lock"
flock -n "$LOCK_FD"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" watchdog --max-age 1 >/dev/null
flock -u "$LOCK_FD"
exec {LOCK_FD}>&-

# A configured max age works without the CLI option.
CONFIG_WITH_WATCHDOG="$TEST_DIRECTORY/config-with-watchdog.yaml"
cp "$CONFIG_FILE" "$CONFIG_WITH_WATCHDOG"
cat >>"$CONFIG_WITH_WATCHDOG" <<'EOF'
watchdog:
  max_age_hours: 1
  jobs: [watchdog]
EOF
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_WITH_WATCHDOG" watchdog >/dev/null

# The CLI threshold overrides the configured one. This complete bundle is two
# hours old, so it is fresh only for the supplied three-hour threshold.
OVERRIDE_DIRECTORY="$TEST_DIRECTORY/override"
OVERRIDE_CONFIG="$TEST_DIRECTORY/override.yaml"
mkdir -p "$OVERRIDE_DIRECTORY"
write_config "$OVERRIDE_CONFIG" "$OVERRIDE_DIRECTORY"
cat >>"$OVERRIDE_CONFIG" <<'EOF'
watchdog:
  max_age_hours: 1
EOF
OVERRIDE_TIMESTAMP=$(date -u -d '2 hours ago' +%Y%m%dT%H%M%SZ)
OVERRIDE_ID="watchdog-host_watchdog_${OVERRIDE_TIMESTAMP}_feedbeef"
make_complete_bundle "$OVERRIDE_DIRECTORY" "$OVERRIDE_ID"
"$PROJECT_DIRECTORY/backfort.sh" -c "$OVERRIDE_CONFIG" watchdog --max-age 3 >/dev/null

# The latest valid copy is chosen across every destination, not only the first.
MULTI_PRIMARY_DIRECTORY="$TEST_DIRECTORY/multi-primary"
MULTI_REPLICA_DIRECTORY="$TEST_DIRECTORY/multi-replica"
MULTI_CONFIG="$TEST_DIRECTORY/multi.yaml"
mkdir -p "$MULTI_PRIMARY_DIRECTORY" "$MULTI_REPLICA_DIRECTORY"
write_two_destination_config "$MULTI_CONFIG" "$MULTI_PRIMARY_DIRECTORY" "$MULTI_REPLICA_DIRECTORY"
make_complete_bundle "$MULTI_PRIMARY_DIRECTORY" 'watchdog-host_watchdog_20000101T000000Z_deadbeef'
MULTI_LATEST_ID="watchdog-host_watchdog_$(date -u +%Y%m%dT%H%M%SZ)_cafebabe"
make_complete_bundle "$MULTI_REPLICA_DIRECTORY" "$MULTI_LATEST_ID"
MULTI_OUTPUT=$("$PROJECT_DIRECTORY/backfort.sh" -c "$MULTI_CONFIG" watchdog --max-age 1)
grep -Fq "backup_id=$MULTI_LATEST_ID" <<<"$MULTI_OUTPUT"

STALE_DIRECTORY="$TEST_DIRECTORY/stale"
STALE_CONFIG="$TEST_DIRECTORY/stale.yaml"
write_config "$STALE_CONFIG" "$STALE_DIRECTORY"
STALE_ID='watchdog-host_watchdog_20000101T000000Z_deadbeef'
make_complete_bundle "$STALE_DIRECTORY" "$STALE_ID"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$STALE_CONFIG" watchdog --max-age 1 \
  >"$TEST_DIRECTORY/stale.stdout" 2>"$TEST_DIRECTORY/stale.stderr"; then
  printf 'expected stale watchdog result\n' >&2
  exit 1
else
  STALE_RESULT=$?
fi
[[ $STALE_RESULT -eq 3 ]]
grep -Fq "backup_id=$STALE_ID" "$TEST_DIRECTORY/stale.stderr"
grep -Fq 'age_seconds=' "$TEST_DIRECTORY/stale.stderr"

EMPTY_DIRECTORY="$TEST_DIRECTORY/empty"
EMPTY_CONFIG="$TEST_DIRECTORY/empty.yaml"
mkdir -p "$EMPTY_DIRECTORY"
write_config "$EMPTY_CONFIG" "$EMPTY_DIRECTORY"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$EMPTY_CONFIG" watchdog --max-age 1 \
  >"$TEST_DIRECTORY/empty.stdout" 2>"$TEST_DIRECTORY/empty.stderr"; then
  printf 'expected no-backup watchdog result\n' >&2
  exit 1
else
  EMPTY_RESULT=$?
fi
[[ $EMPTY_RESULT -eq 3 ]]
grep -Fq 'last_backup=none' "$TEST_DIRECTORY/empty.stderr"

INCOMPLETE_DIRECTORY="$TEST_DIRECTORY/incomplete"
INCOMPLETE_CONFIG="$TEST_DIRECTORY/incomplete.yaml"
mkdir -p "$INCOMPLETE_DIRECTORY"
write_config "$INCOMPLETE_CONFIG" "$INCOMPLETE_DIRECTORY"
printf '%s\n' 'watchdog-host_watchdog_20000101T000000Z_cafebabe' \
  >"$INCOMPLETE_DIRECTORY/watchdog-host_watchdog_20000101T000000Z_cafebabe.complete"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$INCOMPLETE_CONFIG" watchdog --max-age 1 \
  >"$TEST_DIRECTORY/incomplete.stdout" 2>"$TEST_DIRECTORY/incomplete.stderr"; then
  printf 'expected incomplete bundle to be ignored\n' >&2
  exit 1
else
  INCOMPLETE_RESULT=$?
fi
[[ $INCOMPLETE_RESULT -eq 3 ]]
grep -Fq 'last_backup=none' "$TEST_DIRECTORY/incomplete.stderr"

printf '%s\n' 'not-a-backup-id' >"$INCOMPLETE_DIRECTORY/not-a-backup-id.complete"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$INCOMPLETE_CONFIG" watchdog --max-age 1 \
  >"$TEST_DIRECTORY/malformed.stdout" 2>"$TEST_DIRECTORY/malformed.stderr"; then
  printf 'expected malformed backup ID to be ignored\n' >&2
  exit 1
else
  MALFORMED_RESULT=$?
fi
[[ $MALFORMED_RESULT -eq 3 ]]
grep -Fq 'backup_id=not-a-backup-id parse_error=1' "$TEST_DIRECTORY/malformed.stderr"

BAD_CONFIG="$TEST_DIRECTORY/bad-watchdog.yaml"
cp "$CONFIG_FILE" "$BAD_CONFIG"
cat >>"$BAD_CONFIG" <<'EOF'
watchdog:
  max_age_hours: 1
  unexpected: true
EOF
if "$PROJECT_DIRECTORY/backfort.sh" -c "$BAD_CONFIG" watchdog \
  >"$TEST_DIRECTORY/bad.stdout" 2>"$TEST_DIRECTORY/bad.stderr"; then
  printf 'expected unknown watchdog key to be rejected\n' >&2
  exit 1
else
  BAD_RESULT=$?
fi
[[ $BAD_RESULT -eq 2 ]]
grep -Fq 'unknown-config-key path=.watchdog key=unexpected' "$TEST_DIRECTORY/bad.stderr"

printf 'Backfort watchdog test passed.\n'
