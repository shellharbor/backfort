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
RESTORE_DIRECTORY="$TEST_DIRECTORY/restore"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY"
printf 'portable data\n' >"$SOURCE_DIRECTORY/portable.txt"
mkfifo "$SOURCE_DIRECTORY/live.pipe"
printf 'tab name\n' >"$SOURCE_DIRECTORY/tab"$'\t'"name"
printf 'newline name\n' >"$SOURCE_DIRECTORY/line"$'\n'"name"
printf -v INVALID_NAME '%s' "$SOURCE_DIRECTORY/invalid-"$'\xff'
printf 'non-utf8 name\n' >"$INVALID_NAME"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: archive-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: resilient
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 2, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

complete_count() {
  find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -type f | wc -l
}

# A non-regular FIFO, and file names containing a tab, a newline, or invalid
# UTF-8 bytes would each corrupt Backfort's own line-oriented tar listing or
# UTF-8 YAML manifest. The whole job fails instead of silently publishing a
# backup that is missing all four of them and reporting it as a success (a
# leading space alone, by contrast, is not a hazard here: see
# tests/unreadable-file.sh, which proves that name is archived unchanged).
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >"$TEST_DIRECTORY/run.out" 2>"$TEST_DIRECTORY/run.err"; then
  printf 'expected unsupported archive members to fail the backup\n' >&2
  cat "$TEST_DIRECTORY/run.err" >&2
  exit 1
else
  RUN_STATUS=$?
fi
[[ $RUN_STATUS -eq 3 ]]
grep -Fq 'message=unsupported-entries-removed count=4' "$TEST_DIRECTORY/run.err"
[[ $(grep -Fc 'message=unsupported-archive-member-removed' "$TEST_DIRECTORY/run.err") -eq 4 ]]
if grep -Fq 'backup-succeeded' "$TEST_DIRECTORY/run.err"; then
  printf 'a backup missing an unsupported member must never report success\n' >&2
  exit 1
fi
[[ $(complete_count) -eq 0 ]]

# Once the offending paths are removed, the job succeeds normally and the
# one portable, ordinary file restores unchanged.
rm -f -- "$SOURCE_DIRECTORY/live.pipe" "$SOURCE_DIRECTORY/tab"$'\t'"name" \
  "$SOURCE_DIRECTORY/line"$'\n'"name" "$INVALID_NAME"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job resilient --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" restore latest --job resilient --to "$RESTORE_DIRECTORY"
cmp "$SOURCE_DIRECTORY/portable.txt" "$RESTORE_DIRECTORY$SOURCE_DIRECTORY/portable.txt"
[[ $(complete_count) -eq 1 ]]

printf 'Backfort archive resilience test passed.\n'
