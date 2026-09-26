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
OTHER_SOURCE_DIRECTORY="$TEST_DIRECTORY/other-source"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"

mkdir -p "$SOURCE_DIRECTORY/subdirectory" "$OTHER_SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY"
printf 'original content\n' >"$SOURCE_DIRECTORY/changed.txt"
printf 'remove me\n' >"$SOURCE_DIRECTORY/subdirectory/removed.txt"
printf 'other job\n' >"$OTHER_SOURCE_DIRECTORY/other.txt"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: diff-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: alpha
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 3, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
  - name: beta
    source:
      type: files
      paths: ["$OTHER_SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 1, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run --job alpha
ALPHA_ID_ONE=$(basename -- "$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -print -quit)" .complete)

# Preserve directory mtimes so this fixture has exactly one entry in each diff
# category: changed.txt, added.txt and subdirectory/removed.txt.
touch -r "$SOURCE_DIRECTORY" "$TEST_DIRECTORY/source-directory-mtime"
touch -r "$SOURCE_DIRECTORY/subdirectory" "$TEST_DIRECTORY/subdirectory-mtime"
printf 'changed content with a different size\n' >"$SOURCE_DIRECTORY/changed.txt"
rm -- "$SOURCE_DIRECTORY/subdirectory/removed.txt"
printf 'new content\n' >"$SOURCE_DIRECTORY/added.txt"
touch -r "$TEST_DIRECTORY/source-directory-mtime" "$SOURCE_DIRECTORY"
touch -r "$TEST_DIRECTORY/subdirectory-mtime" "$SOURCE_DIRECTORY/subdirectory"

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run --job alpha
ALPHA_ID_TWO=""
while IFS= read -r marker; do
  candidate=${marker%.complete}
  [[ $candidate == "$ALPHA_ID_ONE" ]] || ALPHA_ID_TWO=$candidate
done < <(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -printf '%f\n')
[[ -n $ALPHA_ID_TWO ]]

ARCHIVE_PREFIX=${SOURCE_DIRECTORY#/}
DIFF_TEXT=$("$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" diff "$ALPHA_ID_ONE" "$ALPHA_ID_TWO")
grep -Fq "diff=added path=$ARCHIVE_PREFIX/added.txt" <<<"$DIFF_TEXT"
grep -Fq "diff=removed path=$ARCHIVE_PREFIX/subdirectory/removed.txt" <<<"$DIFF_TEXT"
grep -Fq "diff=modified path=$ARCHIVE_PREFIX/changed.txt" <<<"$DIFF_TEXT"
grep -Fxq 'added=1 removed=1 modified=1' <<<"$DIFF_TEXT"

NO_CHANGE_TEXT=$("$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" diff "$ALPHA_ID_TWO" "$ALPHA_ID_TWO")
grep -Fxq 'added=0 removed=0 modified=0' <<<"$NO_CHANGE_TEXT"

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" diff "$ALPHA_ID_ONE" "$ALPHA_ID_TWO" --from local --json \
  >"$TEST_DIRECTORY/diff.json"
[[ $(yq eval '.summary.added' "$TEST_DIRECTORY/diff.json") == 1 ]]
[[ $(yq eval '.summary.removed' "$TEST_DIRECTORY/diff.json") == 1 ]]
[[ $(yq eval '.summary.modified' "$TEST_DIRECTORY/diff.json") == 1 ]]
[[ $(yq eval ".added[0].path == \"$ARCHIVE_PREFIX/added.txt\"" "$TEST_DIRECTORY/diff.json") == true ]]

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run --job beta
BETA_ID=$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -printf '%f\n' \
  | while IFS= read -r marker; do
      candidate=${marker%.complete}
      [[ $candidate == "$ALPHA_ID_ONE" || $candidate == "$ALPHA_ID_TWO" ]] || printf '%s\n' "$candidate"
    done)
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" diff "$ALPHA_ID_ONE" "$BETA_ID" --from local \
  >"$TEST_DIRECTORY/different-job.stdout" 2>"$TEST_DIRECTORY/different-job.stderr"; then
  printf 'expected different jobs to be rejected\n' >&2
  exit 1
else
  DIFFERENT_JOB_RESULT=$?
fi
[[ $DIFFERENT_JOB_RESULT -eq 2 ]]
grep -Fq 'jobs-do-not-match' "$TEST_DIRECTORY/different-job.stderr"

rm -- "$BACKUP_DIRECTORY/$ALPHA_ID_TWO.complete"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" diff "$ALPHA_ID_ONE" "$ALPHA_ID_TWO" --from local \
  >"$TEST_DIRECTORY/no-marker.stdout" 2>"$TEST_DIRECTORY/no-marker.stderr"; then
  printf 'expected missing completion marker to be rejected\n' >&2
  exit 1
else
  NO_MARKER_RESULT=$?
fi
[[ $NO_MARKER_RESULT -eq 2 ]]
grep -Fq "backup_id=$ALPHA_ID_TWO destination=local" "$TEST_DIRECTORY/no-marker.stderr"
printf '%s\n' "$ALPHA_ID_TWO" >"$BACKUP_DIRECTORY/$ALPHA_ID_TWO.complete"

PAYLOAD_FILE=$(yq eval -r '.payload_file' "$BACKUP_DIRECTORY/$ALPHA_ID_TWO.metadata.json")
tar --delete --file "$BACKUP_DIRECTORY/$PAYLOAD_FILE" manifest.json
printf '{"broken":' >"$TEST_DIRECTORY/manifest.json"
tar --append --file "$BACKUP_DIRECTORY/$PAYLOAD_FILE" --directory "$TEST_DIRECTORY" manifest.json
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" diff "$ALPHA_ID_ONE" "$ALPHA_ID_TWO" --from local \
  >"$TEST_DIRECTORY/bad-manifest.stdout" 2>"$TEST_DIRECTORY/bad-manifest.stderr"; then
  printf 'expected an invalid manifest to be rejected\n' >&2
  exit 1
else
  BAD_MANIFEST_RESULT=$?
fi
[[ $BAD_MANIFEST_RESULT -eq 2 ]]
grep -Fq "backup_id=$ALPHA_ID_TWO destination=local message=invalid-manifest" "$TEST_DIRECTORY/bad-manifest.stderr"

printf 'Backfort diff test passed.\n'
