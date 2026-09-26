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
CANCEL_DIRECTORY="$TEST_DIRECTORY/cancelled"
NONTTY_DIRECTORY="$TEST_DIRECTORY/non-tty"
INVALID_DIRECTORY="$TEST_DIRECTORY/invalid"
NONEMPTY_DIRECTORY="$TEST_DIRECTORY/nonempty"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
EMPTY_CONFIG_FILE="$TEST_DIRECTORY/empty-config.yaml"
MULTI_CONFIG_FILE="$TEST_DIRECTORY/multi-config.yaml"

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: pick-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: pick
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 3, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

printf 'first recovery version\n' >"$SOURCE_DIRECTORY/version.txt"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
FIRST_ID=$(basename -- "$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -print -quit)" .complete)

printf 'second recovery version\n' >"$SOURCE_DIRECTORY/version.txt"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
SECOND_ID=''
while IFS= read -r marker; do
  candidate=${marker%.complete}
  [[ $candidate == "$FIRST_ID" ]] || SECOND_ID=$candidate
done < <(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -printf '%f\n')
[[ -n $SECOND_ID ]]

# The test-only TTY hook lets a pipe supply the scripted answer; production
# invocations still require both standard streams to be actual terminals.
printf '2\n' | BACKFORT_TEST_ASSUME_TTY=1 "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore --pick --job pick --to "$RESTORE_DIRECTORY" \
  >"$TEST_DIRECTORY/pick.stdout" 2>"$TEST_DIRECTORY/pick.stderr"
grep -q '^#' "$TEST_DIRECTORY/pick.stdout"
grep -Fq 'Restore #>' "$TEST_DIRECTORY/pick.stdout"
SELECTED_ID=$(sed -n 's/.*selected=\([^ ]*\) to=.*/\1/p' "$TEST_DIRECTORY/pick.stdout")
[[ -n $SELECTED_ID ]]
case "$SELECTED_ID" in
  "$FIRST_ID") EXPECTED_CONTENT='first recovery version' ;;
  "$SECOND_ID") EXPECTED_CONTENT='second recovery version' ;;
  *) printf 'unexpected selected backup: %s\n' "$SELECTED_ID" >&2; exit 1 ;;
esac
[[ $(<"$RESTORE_DIRECTORY$SOURCE_DIRECTORY/version.txt") == "$EXPECTED_CONTENT" ]]

printf 'q\n' | BACKFORT_TEST_ASSUME_TTY=1 "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore --pick --job pick --to "$CANCEL_DIRECTORY" \
  >"$TEST_DIRECTORY/cancel.stdout" 2>"$TEST_DIRECTORY/cancel.stderr"
grep -Fq 'restore cancelled' "$TEST_DIRECTORY/cancel.stdout"
[[ ! -e $CANCEL_DIRECTORY ]]

if printf '1\n' | "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore --pick --job pick --to "$NONTTY_DIRECTORY" \
  >"$TEST_DIRECTORY/non-tty.stdout" 2>"$TEST_DIRECTORY/non-tty.stderr"; then
  printf 'expected non-TTY restore --pick to fail\n' >&2
  exit 1
else
  NONTTY_RESULT=$?
fi
[[ $NONTTY_RESULT -eq 2 ]]
grep -Fq 'requires an interactive terminal; pass a backup ID instead' "$TEST_DIRECTORY/non-tty.stderr"
[[ ! -e $NONTTY_DIRECTORY ]]

if BACKFORT_TEST_ASSUME_TTY=1 "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore "$FIRST_ID" --pick --to "$TEST_DIRECTORY/id-with-pick" \
  >"$TEST_DIRECTORY/id-with-pick.stdout" 2>"$TEST_DIRECTORY/id-with-pick.stderr"; then
  printf 'expected an ID with --pick to fail\n' >&2
  exit 1
else
  ID_WITH_PICK_RESULT=$?
fi
[[ $ID_WITH_PICK_RESULT -eq 2 ]]
grep -Fq 'restore-pick-requires-either-id-or-pick' "$TEST_DIRECTORY/id-with-pick.stderr"

yq eval '.jobs += [(.jobs[0] | .name = "empty")]' "$CONFIG_FILE" >"$EMPTY_CONFIG_FILE"
if BACKFORT_TEST_ASSUME_TTY=1 "$PROJECT_DIRECTORY/backfort.sh" -c "$EMPTY_CONFIG_FILE" \
  restore --pick --job empty --to "$TEST_DIRECTORY/empty" \
  >"$TEST_DIRECTORY/empty.stdout" 2>"$TEST_DIRECTORY/empty.stderr"; then
  printf 'expected restore --pick with no versions to fail\n' >&2
  exit 1
else
  EMPTY_RESULT=$?
fi
[[ $EMPTY_RESULT -eq 3 ]]
grep -Fq 'no completed backups for job empty' "$TEST_DIRECTORY/empty.stderr"
! grep -Fq 'Restore #>' "$TEST_DIRECTORY/empty.stdout"

if printf '99\nabc\n0\n' | BACKFORT_TEST_ASSUME_TTY=1 "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore --pick --job pick --to "$INVALID_DIRECTORY" \
  >"$TEST_DIRECTORY/invalid.stdout" 2>"$TEST_DIRECTORY/invalid.stderr"; then
  printf 'expected three invalid selections to fail\n' >&2
  exit 1
else
  INVALID_RESULT=$?
fi
[[ $INVALID_RESULT -eq 2 ]]
[[ $(grep -c 'invalid selection' "$TEST_DIRECTORY/invalid.stderr") -eq 3 ]]
grep -Fq 'restore cancelled' "$TEST_DIRECTORY/invalid.stderr"
[[ ! -e $INVALID_DIRECTORY ]]

yq eval '.jobs += [(.jobs[0] | .name = "second-job")]' "$CONFIG_FILE" >"$MULTI_CONFIG_FILE"
if BACKFORT_TEST_ASSUME_TTY=1 "$PROJECT_DIRECTORY/backfort.sh" -c "$MULTI_CONFIG_FILE" \
  restore --pick --to "$TEST_DIRECTORY/multi-job" \
  >"$TEST_DIRECTORY/multi.stdout" 2>"$TEST_DIRECTORY/multi.stderr"; then
  printf 'expected restore --pick without --job on multi-job config to fail\n' >&2
  exit 1
else
  MULTI_RESULT=$?
fi
[[ $MULTI_RESULT -eq 2 ]]
grep -Fq 'requires --job when config has multiple jobs' "$TEST_DIRECTORY/multi.stderr"

mkdir -p "$NONEMPTY_DIRECTORY"
printf 'must remain\n' >"$NONEMPTY_DIRECTORY/existing.txt"
if printf '1\n' | BACKFORT_TEST_ASSUME_TTY=1 "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore --pick --job pick --to "$NONEMPTY_DIRECTORY" \
  >"$TEST_DIRECTORY/nonempty.stdout" 2>"$TEST_DIRECTORY/nonempty.stderr"; then
  printf 'expected restore into a nonempty directory to fail\n' >&2
  exit 1
else
  NONEMPTY_RESULT=$?
fi
[[ $NONEMPTY_RESULT -eq 2 ]]
grep -Fq 'selected=' "$TEST_DIRECTORY/nonempty.stdout"
grep -Fq 'restore-target-must-be-empty' "$TEST_DIRECTORY/nonempty.stderr"
[[ $(<"$NONEMPTY_DIRECTORY/existing.txt") == 'must remain' ]]

printf 'Backfort interactive restore pick test passed.\n'
