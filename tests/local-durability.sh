#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d)

cleanup() {
  case "$TEST_DIRECTORY" in
    /tmp/*|/var/tmp/*) command rm -rf -- "$TEST_DIRECTORY" ;;
  esac
}

# shellcheck source=/dev/null
source <(sed '/^main "\$@"$/d' "$PROJECT_DIRECTORY/backfort.sh")
trap cleanup EXIT

DESTINATION_DIRECTORY="$TEST_DIRECTORY/destination"
WORK_DIRECTORY="$TEST_DIRECTORY/work"
SYNC_LOG="$TEST_DIRECTORY/sync.log"
REMOVE_LOG="$TEST_DIRECTORY/remove.log"
BACKUP_ID='durability-host_files_20250101T000000Z_00000001'
FAILED_ID='durability-host_files_20250101T000001Z_00000002'

mkdir -p "$DESTINATION_DIRECTORY" "$WORK_DIRECTORY"
printf 'payload\n' >"$WORK_DIRECTORY/$BACKUP_ID.tar"
printf '{"backup_id":"%s"}\n' "$BACKUP_ID" >"$WORK_DIRECTORY/$BACKUP_ID.metadata.json"
printf 'checksum\n' >"$WORK_DIRECTORY/$BACKUP_ID.sha256"
printf 'failed payload\n' >"$WORK_DIRECTORY/$FAILED_ID.tar"
printf '{"backup_id":"%s"}\n' "$FAILED_ID" >"$WORK_DIRECTORY/$FAILED_ID.metadata.json"
printf 'failed checksum\n' >"$WORK_DIRECTORY/$FAILED_ID.sha256"

cfg() {
  [[ $1 == '.destinations[0].name' ]] || return 1
  printf 'local\n'
}

destination_local_path() {
  [[ $1 == 0 ]] || return 1
  printf '%s\n' "$DESTINATION_DIRECTORY"
}

sync() {
  printf '%s\n' "$@" >>"$SYNC_LOG"
  [[ ${BACKFORT_TEST_FAIL_SYNC:-false} != true ]]
}

publish_to_local_destination 0 "$BACKUP_ID" \
  "$WORK_DIRECTORY/$BACKUP_ID.tar" \
  "$WORK_DIRECTORY/$BACKUP_ID.metadata.json" \
  "$WORK_DIRECTORY/$BACKUP_ID.sha256"

mapfile -t sync_arguments <"$SYNC_LOG"
[[ ${sync_arguments[0]} == -f && ${sync_arguments[1]} == -- ]]
[[ ${sync_arguments[2]} == "$DESTINATION_DIRECTORY/$BACKUP_ID.tar" ]]
[[ ${sync_arguments[3]} == "$DESTINATION_DIRECTORY/$BACKUP_ID.metadata.json" ]]
[[ ${sync_arguments[4]} == "$DESTINATION_DIRECTORY/$BACKUP_ID.sha256" ]]
[[ ${sync_arguments[5]} == -f && ${sync_arguments[6]} == -- ]]
[[ ${sync_arguments[7]} == "$DESTINATION_DIRECTORY/$BACKUP_ID.complete" ]]
[[ ${sync_arguments[8]} == "$DESTINATION_DIRECTORY" ]]
[[ -f $DESTINATION_DIRECTORY/$BACKUP_ID.complete ]]

# A durability failure before the commit marker must publish no recoverable
# bundle and must clean up every copied object.
export BACKFORT_TEST_FAIL_SYNC=true
if publish_to_local_destination 0 "$FAILED_ID" \
  "$WORK_DIRECTORY/$FAILED_ID.tar" \
  "$WORK_DIRECTORY/$FAILED_ID.metadata.json" \
  "$WORK_DIRECTORY/$FAILED_ID.sha256"; then
  printf 'expected a failed durability sync to reject publication\n' >&2
  exit 1
else
  PUBLISH_RESULT=$?
fi
[[ $PUBLISH_RESULT -eq 3 ]]
[[ ! -e $DESTINATION_DIRECTORY/$FAILED_ID.complete ]]
[[ ! -e $DESTINATION_DIRECTORY/$FAILED_ID.tar ]]
[[ ! -e $DESTINATION_DIRECTORY/$FAILED_ID.metadata.json ]]
[[ ! -e $DESTINATION_DIRECTORY/$FAILED_ID.sha256 ]]
unset BACKFORT_TEST_FAIL_SYNC

destination_type() {
  [[ $1 == 0 ]] || return 1
  printf 'local\n'
}

destination_object() {
  [[ $1 == 0 ]] || return 1
  printf '%s/%s\n' "$DESTINATION_DIRECTORY" "$2"
}

backup_uses_minisign() {
  return 1
}

rm() {
  printf '%s\n' "$@" >>"$REMOVE_LOG"
  command rm "$@"
}

delete_backup_bundle 0 "$BACKUP_ID" "$BACKUP_ID.tar"
mapfile -t remove_arguments <"$REMOVE_LOG"
[[ ${remove_arguments[0]} == -f && ${remove_arguments[1]} == -- ]]
[[ ${remove_arguments[2]} == "$DESTINATION_DIRECTORY/$BACKUP_ID.complete" ]]
[[ ${remove_arguments[3]} == "$DESTINATION_DIRECTORY/$BACKUP_ID.tar" ]]
[[ ${remove_arguments[4]} == "$DESTINATION_DIRECTORY/$BACKUP_ID.metadata.json" ]]
[[ ${remove_arguments[5]} == "$DESTINATION_DIRECTORY/$BACKUP_ID.sha256" ]]
[[ ! -e $DESTINATION_DIRECTORY/$BACKUP_ID.complete ]]

printf 'Backfort local durability test passed.\n'
