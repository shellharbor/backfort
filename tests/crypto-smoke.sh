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
BIN_DIRECTORY="$TEST_DIRECTORY/bin"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
SIGNING_KEY="$TEST_DIRECTORY/minisign.key"

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY" "$BIN_DIRECTORY"
printf 'encrypted and signed content\n' >"$SOURCE_DIRECTORY/important.txt"
printf 'test signing key\n' >"$SIGNING_KEY"
ln -s "$PROJECT_DIRECTORY/tests/fake-age.sh" "$BIN_DIRECTORY/age"
ln -s "$PROJECT_DIRECTORY/tests/fake-minisign.sh" "$BIN_DIRECTORY/minisign"

export BACKFORT_FAKE_AGE_LOG="$TEST_DIRECTORY/age.log"
export BACKFORT_AGE_RECIPIENT_PRIMARY='age1primaryrecipient'
export BACKFORT_AGE_RECIPIENT_RECOVERY='age1recoveryrecipient'
export BACKFORT_AGE_IDENTITY_FILE="$TEST_DIRECTORY/age.key"
export BACKFORT_MINISIGN_SECRET_KEY="$SIGNING_KEY"
export BACKFORT_MINISIGN_PUBLIC_KEY='RWQfakepublickey'
export PATH="$BIN_DIRECTORY:$PATH"
printf 'test identity\n' >"$BACKFORT_AGE_IDENTITY_FILE"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: crypto-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: crypto
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption:
      method: age
      recipients_env: [BACKFORT_AGE_RECIPIENT_PRIMARY, BACKFORT_AGE_RECIPIENT_RECOVERY]
      identity_file_env: BACKFORT_AGE_IDENTITY_FILE
    signing:
      method: minisign
      secret_key_env: BACKFORT_MINISIGN_SECRET_KEY
      public_key_env: BACKFORT_MINISIGN_PUBLIC_KEY
    retention: {keep_last: 1, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
[[ $(grep -c '^recipient ' "$BACKFORT_FAKE_AGE_LOG") -eq 2 ]]

BACKUP_ID=$(basename -- "$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -print -quit)" .complete)
SIGNATURE_FILE="$BACKUP_DIRECTORY/$BACKUP_ID.minisig"
[[ -f $SIGNATURE_FILE ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job crypto --quick
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job crypto --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" restore latest --job crypto --to "$RESTORE_DIRECTORY"
diff -r "$SOURCE_DIRECTORY" "$RESTORE_DIRECTORY$SOURCE_DIRECTORY"

printf 'tampered signature\n' >"$SIGNATURE_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job crypto --quick; then
  printf 'expected signature verification to fail after tampering\n' >&2
  exit 1
else
  VERIFY_RESULT=$?
fi
[[ $VERIFY_RESULT -eq 3 ]]

printf 'Backfort crypto smoke test passed.\n'
