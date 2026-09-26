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
LOCAL_DIRECTORY="$TEST_DIRECTORY/local"
REMOTE_DIRECTORY="$TEST_DIRECTORY/remotes"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
BIN_DIRECTORY="$TEST_DIRECTORY/bin"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"

mkdir -p "$SOURCE_DIRECTORY" "$LOCAL_DIRECTORY" "$REMOTE_DIRECTORY/archives/period" \
  "$STATE_DIRECTORY" "$TEMP_DIRECTORY" "$BIN_DIRECTORY"
printf 'period deletion fixture\n' >"$SOURCE_DIRECTORY/important.txt"
ln -s "$PROJECT_DIRECTORY/tests/fake-rclone.sh" "$BIN_DIRECTORY/rclone"

export BACKFORT_FAKE_RCLONE_ROOT="$REMOTE_DIRECTORY"
export PATH="$BIN_DIRECTORY:$PATH"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: period-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$LOCAL_DIRECTORY"
  - name: remote
    type: rclone
    remote: fake
    path: archives/period
jobs:
  - name: period
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local, remote]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 3, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

write_bundle() {
  local destination=$1
  local backup_id=$2
  local created_at=$3

  printf 'fixture payload\n' >"$destination/$backup_id.tar.gz"
  printf 'fixture checksum\n' >"$destination/$backup_id.sha256"
  cat >"$destination/$backup_id.metadata.json" <<EOF
backup_id: "$backup_id"
job: period
created_at: "$created_at"
payload_file: "$backup_id.tar.gz"
signing:
  method: none
EOF
  printf '%s\n' "$backup_id" >"$destination/$backup_id.complete"
}

JANUARY_FIRST='period-host_period_20250101T000000Z_00000001'
JANUARY_PINNED='period-host_period_20250115T000000Z_00000002'
JANUARY_LAST='period-host_period_20250131T235959Z_00000003'
FEBRUARY_FIRST='period-host_period_20250201T000000Z_00000004'

for destination in "$LOCAL_DIRECTORY" "$REMOTE_DIRECTORY/archives/period"; do
  write_bundle "$destination" "$JANUARY_FIRST" '2025-01-01T00:00:00Z'
  write_bundle "$destination" "$JANUARY_PINNED" '2025-01-15T00:00:00Z'
  write_bundle "$destination" "$JANUARY_LAST" '2025-01-31T23:59:59Z'
  write_bundle "$destination" "$FEBRUARY_FIRST" '2025-02-01T00:00:00Z'
done

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" pin "$JANUARY_PINNED" --reason 'manual recovery point'

# The plan includes both inclusive date boundaries, skips pins, and changes no
# objects. A confirmation is intentionally not accepted as implicit.
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" delete \
  --job period --since 2025-01-01 --until 2025-01-31 --dry-run \
  >"$TEST_DIRECTORY/plan.stdout" 2>"$TEST_DIRECTORY/plan.stderr"
grep -Fq "backup_id=$JANUARY_FIRST" "$TEST_DIRECTORY/plan.stderr"
grep -Fq "backup_id=$JANUARY_LAST" "$TEST_DIRECTORY/plan.stderr"
grep -Fq "backup_id=$JANUARY_PINNED reason=pinned" "$TEST_DIRECTORY/plan.stderr"
! grep -Fq "backup_id=$FEBRUARY_FIRST" "$TEST_DIRECTORY/plan.stderr"
[[ -f "$LOCAL_DIRECTORY/$JANUARY_FIRST.complete" ]]
[[ -f "$REMOTE_DIRECTORY/archives/period/$JANUARY_LAST.complete" ]]

if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" delete \
  --job period --since 2025-01-01 --until 2025-01-31 \
  >"$TEST_DIRECTORY/unconfirmed.stdout" 2>"$TEST_DIRECTORY/unconfirmed.stderr"; then
  printf 'expected delete without --confirm to fail\n' >&2
  exit 1
else
  UNCONFIRMED_RESULT=$?
fi
[[ $UNCONFIRMED_RESULT -eq 2 ]]
grep -Fq 'delete-period-requires-confirm-or-dry-run' "$TEST_DIRECTORY/unconfirmed.stderr"

# A selected destination is removed independently, leaving the remote replica
# and the pinned recovery point intact.
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" delete \
  --job period --since 2025-01-01 --until 2025-01-31 --from local --confirm
[[ ! -e "$LOCAL_DIRECTORY/$JANUARY_FIRST.complete" ]]
[[ ! -e "$LOCAL_DIRECTORY/$JANUARY_FIRST.tar.gz" ]]
[[ ! -e "$LOCAL_DIRECTORY/$JANUARY_LAST.complete" ]]
[[ -f "$LOCAL_DIRECTORY/$JANUARY_PINNED.complete" ]]
[[ -f "$LOCAL_DIRECTORY/$FEBRUARY_FIRST.complete" ]]
[[ -f "$REMOTE_DIRECTORY/archives/period/$JANUARY_FIRST.complete" ]]

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" delete \
  --job period --since 2025-01-01 --until 2025-01-31 --from remote --confirm
[[ ! -e "$REMOTE_DIRECTORY/archives/period/$JANUARY_FIRST.complete" ]]
[[ ! -e "$REMOTE_DIRECTORY/archives/period/$JANUARY_LAST.complete" ]]
[[ -f "$REMOTE_DIRECTORY/archives/period/$JANUARY_PINNED.complete" ]]
[[ -f "$REMOTE_DIRECTORY/archives/period/$FEBRUARY_FIRST.complete" ]]

if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" delete \
  --job period --since 2025-02-30 --until 2025-03-01 --dry-run \
  >"$TEST_DIRECTORY/invalid-date.stdout" 2>"$TEST_DIRECTORY/invalid-date.stderr"; then
  printf 'expected invalid date to fail\n' >&2
  exit 1
else
  INVALID_DATE_RESULT=$?
fi
[[ $INVALID_DATE_RESULT -eq 2 ]]
grep -Fq 'delete-period-invalid-since' "$TEST_DIRECTORY/invalid-date.stderr"

if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" delete \
  --job period --since 2025-03-01 --until 2025-02-28 --dry-run \
  >"$TEST_DIRECTORY/reversed.stdout" 2>"$TEST_DIRECTORY/reversed.stderr"; then
  printf 'expected reversed date range to fail\n' >&2
  exit 1
else
  REVERSED_RESULT=$?
fi
[[ $REVERSED_RESULT -eq 2 ]]
grep -Fq 'delete-period-since-must-not-be-after-until' "$TEST_DIRECTORY/reversed.stderr"

printf 'Backfort delete period test passed.\n'
