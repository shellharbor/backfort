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
printf 'leading name\n' >"$SOURCE_DIRECTORY/ leading-name"
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

if ! "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >"$TEST_DIRECTORY/run.out" 2>"$TEST_DIRECTORY/run.err"; then
  cat "$TEST_DIRECTORY/run.err" >&2
  exit 1
fi
grep -q 'message=unsupported-entries-skipped' "$TEST_DIRECTORY/run.err"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job resilient --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" restore latest --job resilient --to "$RESTORE_DIRECTORY"

RESTORED_SOURCE="$RESTORE_DIRECTORY$SOURCE_DIRECTORY"
cmp "$SOURCE_DIRECTORY/portable.txt" "$RESTORED_SOURCE/portable.txt"
[[ ! -e "$RESTORED_SOURCE/live.pipe" ]]
[[ ! -e "$RESTORED_SOURCE/tab"$'\t'"name" ]]
[[ ! -e "$RESTORED_SOURCE/line"$'\n'"name" ]]
[[ ! -e "$RESTORED_SOURCE/ leading-name" ]]
[[ ! -e "$RESTORED_SOURCE/invalid-"$'\xff' ]]

METADATA_FILE=$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.metadata.json' -print -quit)
[[ $(yq eval '.entries | length' "$METADATA_FILE") -gt 0 ]]
if yq eval -r '.entries[].path' "$METADATA_FILE" | grep -Eq $'(^ |\t|\r)'; then
  printf 'manifest retained an unsupported path\n' >&2
  exit 1
fi

printf 'Backfort archive resilience test passed.\n'
