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
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
RESTORE_DIRECTORY="$TEST_DIRECTORY/restore"
PICK_RESTORE_DIRECTORY="$TEST_DIRECTORY/pick-restore"
REMOTE_DIRECTORY="$TEST_DIRECTORY/remotes"
BIN_DIRECTORY="$TEST_DIRECTORY/bin"
RCLONE_LOG="$TEST_DIRECTORY/rclone.log"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
POLICY_CONFIG_FILE="$TEST_DIRECTORY/policy-config.yaml"

mkdir -p "$SOURCE_DIRECTORY/nested" "$STATE_DIRECTORY" "$TEMP_DIRECTORY" "$REMOTE_DIRECTORY" "$BIN_DIRECTORY"
printf 'remote backup content\n' >"$SOURCE_DIRECTORY/important.txt"
printf 'remote nested content\n' >"$SOURCE_DIRECTORY/nested/nested.txt"
ln -s "$PROJECT_DIRECTORY/tests/fake-rclone.sh" "$BIN_DIRECTORY/rclone"

export BACKFORT_FAKE_RCLONE_ROOT="$REMOTE_DIRECTORY"
export BACKFORT_FAKE_RCLONE_LOG="$RCLONE_LOG"
export PATH="$BIN_DIRECTORY:$PATH"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: rclone-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: remote
    type: rclone
    remote: fake
    path: archives/smoke
jobs:
  - name: remote-smoke
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [remote]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 2, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" --dry-run run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run

REMOTE_BUNDLE_DIRECTORY="$REMOTE_DIRECTORY/archives/smoke"
BACKUP_ID=$(basename -- "$(find "$REMOTE_BUNDLE_DIRECTORY" -maxdepth 1 -name '*.complete' -print -quit)" .complete)
[[ -n $BACKUP_ID ]]
[[ $(tail -n 1 "$RCLONE_LOG") == "copyto $BACKUP_ID.complete" ]]

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" list --job remote-smoke | grep -q $'remote-smoke\tremote'
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" list --job remote-smoke --json >"$TEST_DIRECTORY/list.json"
[[ $(yq eval 'length' "$TEST_DIRECTORY/list.json") -eq 1 ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" pin "$BACKUP_ID" --from remote --reason 'remote recovery point'
[[ -f $REMOTE_BUNDLE_DIRECTORY/$BACKUP_ID.pinned ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" list --job remote-smoke --json >"$TEST_DIRECTORY/pinned-list.json"
[[ $(yq eval '.[0].pinned' "$TEST_DIRECTORY/pinned-list.json") == true ]]
[[ $(yq eval '.[0].pinned_reason' "$TEST_DIRECTORY/pinned-list.json") == 'remote recovery point' ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" unpin "$BACKUP_ID" --from remote
[[ ! -e $REMOTE_BUNDLE_DIRECTORY/$BACKUP_ID.pinned ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" status --job remote-smoke | grep -q $'remote-smoke\tremote'
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job remote-smoke --quick
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job remote-smoke --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" restore latest --job remote-smoke --to "$RESTORE_DIRECTORY"
diff -r "$SOURCE_DIRECTORY" "$RESTORE_DIRECTORY$SOURCE_DIRECTORY"
printf '1\n' | BACKFORT_TEST_ASSUME_TTY=1 "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore --pick --job remote-smoke --to "$PICK_RESTORE_DIRECTORY" \
  >"$TEST_DIRECTORY/pick.stdout" 2>"$TEST_DIRECTORY/pick.stderr"
grep -Fq "selected=$BACKUP_ID" "$TEST_DIRECTORY/pick.stdout"
diff -r "$SOURCE_DIRECTORY" "$PICK_RESTORE_DIRECTORY$SOURCE_DIRECTORY"

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" prune
[[ $(find "$REMOTE_BUNDLE_DIRECTORY" -maxdepth 1 -name '*.complete' | wc -l) -eq 2 ]]

yq eval '.destinations += [{"name": "failing", "type": "rclone", "remote": "failing", "path": "archives/smoke"}] | .jobs[0].destinations = ["remote", "failing"] | .jobs[0].success.min_copies = 2' \
  "$CONFIG_FILE" >"$POLICY_CONFIG_FILE"
BEFORE_POLICY_RUN=$(find "$REMOTE_BUNDLE_DIRECTORY" -maxdepth 1 -name '*.complete' | wc -l)
if "$PROJECT_DIRECTORY/backfort.sh" -c "$POLICY_CONFIG_FILE" run; then
  printf 'expected minimum-copy policy failure\n' >&2
  exit 1
else
  POLICY_RESULT=$?
fi
[[ $POLICY_RESULT -eq 3 ]]
AFTER_POLICY_RUN=$(find "$REMOTE_BUNDLE_DIRECTORY" -maxdepth 1 -name '*.complete' | wc -l)
[[ $AFTER_POLICY_RUN -eq $((BEFORE_POLICY_RUN + 1)) ]]

printf 'Backfort rclone smoke test passed.\n'
