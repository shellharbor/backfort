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

SOURCE_DIRECTORY="$TEST_DIRECTORY/source data"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
RESTORE_DIRECTORY="$TEST_DIRECTORY/restore"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"

mkdir -p "$SOURCE_DIRECTORY/subdirectory" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY"
printf 'hello from Backfort\n' >"$SOURCE_DIRECTORY/important.txt"
printf 'nested content\n' >"$SOURCE_DIRECTORY/subdirectory/nested.txt"
printf 'excluded\n' >"$SOURCE_DIRECTORY/ignored.log"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: smoke-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: smoke
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: ["*.log"]
      follow_symlinks: false
    destinations: [local]
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 2, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" --dry-run run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" list --job smoke
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" list --job smoke --json >"$TEST_DIRECTORY/list.json"
[[ $(yq eval 'length' "$TEST_DIRECTORY/list.json") -eq 1 ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" status --job smoke | grep -q $'smoke\tlocal'
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job smoke --quick
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job smoke --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" restore latest --job smoke --to "$RESTORE_DIRECTORY"

RESTORED_SOURCE="$RESTORE_DIRECTORY${SOURCE_DIRECTORY}"
diff -r --exclude='*.log' "$SOURCE_DIRECTORY" "$RESTORED_SOURCE"
[[ ! -e "$RESTORED_SOURCE/ignored.log" ]]

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
BEFORE_DRY_RUN=$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' | wc -l)
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" prune --dry-run
AFTER_DRY_RUN=$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' | wc -l)
[[ $BEFORE_DRY_RUN -eq 3 && $AFTER_DRY_RUN -eq 3 ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" prune
AFTER_PRUNE=$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' | wc -l)
[[ $AFTER_PRUNE -eq 2 ]]

printf 'Backfort smoke test passed.\n'
