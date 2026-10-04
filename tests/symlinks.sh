#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d /tmp/backfort-symlinks.XXXXXXXX)
cleanup() {
  case "$TEST_DIRECTORY" in
    /tmp/backfort-symlinks.*) rm -rf -- "$TEST_DIRECTORY" ;;
    *) printf 'unexpected test directory: %s\n' "$TEST_DIRECTORY" >&2 ;;
  esac
}
trap cleanup EXIT

SOURCE_DIRECTORY="$TEST_DIRECTORY/source"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
RESTORE_DIRECTORY="$TEST_DIRECTORY/restore"
mkdir -p "$SOURCE_DIRECTORY/private" "$BACKUP_DIRECTORY"
printf 'link recovery evidence\n' >"$SOURCE_DIRECTORY/private/probe.txt"
ln -s private/probe.txt "$SOURCE_DIRECTORY/relative-file"
ln -s private "$SOURCE_DIRECTORY/relative-directory"
ln -s "$SOURCE_DIRECTORY/private/probe.txt" "$SOURCE_DIRECTORY/absolute-file"
ln -s absent.txt "$SOURCE_DIRECTORY/dangling"
ln "$SOURCE_DIRECTORY/private/probe.txt" "$SOURCE_DIRECTORY/hardlink"

cat >"$TEST_DIRECTORY/config.yaml" <<EOF
version: 1
settings:
  host_id: symlink-host
  state_directory: "$TEST_DIRECTORY/state"
  temp_directory: "$TEST_DIRECTORY/work"
  lock_file: "$TEST_DIRECTORY/state/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: files
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

run_backfort() {
  bash "$PROJECT_DIRECTORY/backfort.sh" -c "$TEST_DIRECTORY/config.yaml" "$@"
}
run_backfort doctor
run_backfort run
run_backfort verify latest --job files --full
run_backfort restore latest --job files --to "$RESTORE_DIRECTORY"

RESTORED_SOURCE="$RESTORE_DIRECTORY$SOURCE_DIRECTORY"
[[ $(readlink "$RESTORED_SOURCE/relative-file") == private/probe.txt ]]
[[ $(readlink "$RESTORED_SOURCE/relative-directory") == private ]]
[[ $(readlink "$RESTORED_SOURCE/absolute-file") == "$SOURCE_DIRECTORY/private/probe.txt" ]]
[[ $(readlink "$RESTORED_SOURCE/dangling") == absent.txt ]]
cmp "$SOURCE_DIRECTORY/private/probe.txt" "$RESTORED_SOURCE/relative-file"
cmp "$SOURCE_DIRECTORY/private/probe.txt" "$RESTORED_SOURCE/relative-directory/probe.txt"
[[ $(stat -c %i "$RESTORED_SOURCE/private/probe.txt") == "$(stat -c %i "$RESTORED_SOURCE/hardlink")" ]]
[[ $(find "$BACKUP_DIRECTORY" -maxdepth 1 -type f -name '*.complete' | wc -l) -eq 1 ]]

# Dereferencing remains an explicit alternate policy. A dangling link cannot
# be read in that mode and must be deliberately excluded, not silently lost.
yq eval -i '.jobs[0].source.follow_symlinks = true | .jobs[0].source.exclude = ["*/dangling"]' "$TEST_DIRECTORY/config.yaml"
run_backfort run
run_backfort verify latest --job files --full
run_backfort restore latest --job files --to "$TEST_DIRECTORY/restore-followed"
FOLLOWED_SOURCE="$TEST_DIRECTORY/restore-followed$SOURCE_DIRECTORY"
[[ ! -L $FOLLOWED_SOURCE/relative-file && ! -L $FOLLOWED_SOURCE/relative-directory ]]
[[ ! -L $FOLLOWED_SOURCE/absolute-file ]]
cmp "$SOURCE_DIRECTORY/private/probe.txt" "$FOLLOWED_SOURCE/relative-file"
cmp "$SOURCE_DIRECTORY/private/probe.txt" "$FOLLOWED_SOURCE/absolute-file"
cmp "$SOURCE_DIRECTORY/private/probe.txt" "$FOLLOWED_SOURCE/relative-directory/probe.txt"
[[ $(find "$BACKUP_DIRECTORY" -maxdepth 1 -type f -name '*.complete' | wc -l) -eq 2 ]]
printf 'Backfort symbolic and hard link recovery test passed.\n'
