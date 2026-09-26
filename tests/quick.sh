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
LOCAL_DIRECTORY="$TEST_DIRECTORY/local"
REMOTE_DIRECTORY="$TEST_DIRECTORY/remotes"
RESTORE_DIRECTORY="$TEST_DIRECTORY/restore"
STATE_HOME="$TEST_DIRECTORY/state-home"
BIN_DIRECTORY="$TEST_DIRECTORY/bin"

mkdir -p "$SOURCE_DIRECTORY/subdirectory" "$LOCAL_DIRECTORY" "$REMOTE_DIRECTORY" \
  "$STATE_HOME" "$BIN_DIRECTORY"
printf 'quick backup content\n' >"$SOURCE_DIRECTORY/important.txt"
printf 'nested quick content\n' >"$SOURCE_DIRECTORY/subdirectory/nested.txt"
printf 'excluded quick content\n' >"$SOURCE_DIRECTORY/ignored.log"
ln -s "$PROJECT_DIRECTORY/tests/fake-rclone.sh" "$BIN_DIRECTORY/rclone"

export BACKFORT_FAKE_RCLONE_ROOT="$REMOTE_DIRECTORY"
export XDG_STATE_HOME="$STATE_HOME"
export PATH="$BIN_DIRECTORY:$PATH"

COMMON_ARGUMENTS=(
  "$SOURCE_DIRECTORY"
  --name quick-files
  --to "$LOCAL_DIRECTORY"
  --to rclone:fake:quick/files
  --min-copies 2
  --exclude '*.log'
)

# Dry-run performs the same validation but must not make either a bundle or a
# saved recovery config.
"$PROJECT_DIRECTORY/backfort.sh" --dry-run quick "${COMMON_ARGUMENTS[@]}"
[[ ! -e "$STATE_HOME/backfort/quick/quick-files.yaml" ]]
[[ -z $(find "$LOCAL_DIRECTORY" -maxdepth 1 -name '*.complete' -print -quit) ]]

"$PROJECT_DIRECTORY/backfort.sh" quick "${COMMON_ARGUMENTS[@]}"

LOCAL_PAYLOAD=$(find "$LOCAL_DIRECTORY" -maxdepth 1 -name '*.tar.gz' -print -quit)
REMOTE_PAYLOAD=$(find "$REMOTE_DIRECTORY/quick/files" -maxdepth 1 -name '*.tar.gz' -print -quit)
QUICK_CONFIG_FILE="$STATE_HOME/backfort/quick/quick-files.yaml"
[[ -n $LOCAL_PAYLOAD && -n $REMOTE_PAYLOAD && -f $QUICK_CONFIG_FILE ]]

# The persisted config is sufficient for normal Backfort verification and
# recovery after the original one-off command has exited.
"$PROJECT_DIRECTORY/backfort.sh" -c "$QUICK_CONFIG_FILE" verify latest --job quick-files --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$QUICK_CONFIG_FILE" \
  restore latest --job quick-files --to "$RESTORE_DIRECTORY"

RESTORED_SOURCE="$RESTORE_DIRECTORY$SOURCE_DIRECTORY"
diff -r --exclude='*.log' "$SOURCE_DIRECTORY" "$RESTORED_SOURCE"
[[ ! -e "$RESTORED_SOURCE/ignored.log" ]]

printf 'Backfort quick backup test passed.\n'
