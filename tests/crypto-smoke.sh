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
GPG_SOURCE_DIRECTORY="$TEST_DIRECTORY/gpg-source"
GPG_BACKUP_DIRECTORY="$TEST_DIRECTORY/gpg-backups"
GPG_RESTORE_DIRECTORY="$TEST_DIRECTORY/gpg-restore"
GPG_CONFIG_FILE="$TEST_DIRECTORY/gpg-config.yaml"
SYMMETRIC_GPG_BACKUP_DIRECTORY="$TEST_DIRECTORY/symmetric-gpg-backups"
SYMMETRIC_GPG_RESTORE_DIRECTORY="$TEST_DIRECTORY/symmetric-gpg-restore"
SYMMETRIC_GPG_CONFIG_FILE="$TEST_DIRECTORY/symmetric-gpg-config.yaml"
INVALID_GPG_CONFIG_FILE="$TEST_DIRECTORY/invalid-gpg-config.yaml"
UNKNOWN_GPG_CONFIG_FILE="$TEST_DIRECTORY/unknown-gpg-config.yaml"
INVALID_GPG_FINGERPRINT_CONFIG_FILE="$TEST_DIRECTORY/invalid-gpg-fingerprint-config.yaml"
NON_GPG_IDENTITY_PASSWORD_CONFIG_FILE="$TEST_DIRECTORY/non-gpg-identity-password-config.yaml"
GPG_PRIMARY_FINGERPRINT='0123456789ABCDEF0123456789ABCDEF01234567'
GPG_RECOVERY_FINGERPRINT='89ABCDEF0123456789ABCDEF0123456789ABCDEF'

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY" "$BIN_DIRECTORY" \
  "$GPG_SOURCE_DIRECTORY" "$GPG_BACKUP_DIRECTORY" "$SYMMETRIC_GPG_BACKUP_DIRECTORY"
printf 'encrypted and signed content\n' >"$SOURCE_DIRECTORY/important.txt"
printf 'test signing key\n' >"$SIGNING_KEY"
ln -s "$PROJECT_DIRECTORY/tests/fake-age.sh" "$BIN_DIRECTORY/age"
ln -s "$PROJECT_DIRECTORY/tests/fake-minisign.sh" "$BIN_DIRECTORY/minisign"
export BACKFORT_FAKE_GPG_SCRIPT="$PROJECT_DIRECTORY/tests/fake-gpg.sh"
cat >"$BIN_DIRECTORY/gpg" <<'EOF'
#!/usr/bin/env bash
exec bash "$BACKFORT_FAKE_GPG_SCRIPT" "$@"
EOF
chmod 0755 "$BIN_DIRECTORY/gpg"

export BACKFORT_FAKE_AGE_LOG="$TEST_DIRECTORY/age.log"
export BACKFORT_AGE_RECIPIENT_PRIMARY='age1primaryrecipient'
export BACKFORT_AGE_RECIPIENT_RECOVERY='age1recoveryrecipient'
export BACKFORT_AGE_IDENTITY_FILE="$TEST_DIRECTORY/age.key"
export BACKFORT_MINISIGN_SECRET_KEY="$SIGNING_KEY"
export BACKFORT_MINISIGN_PUBLIC_KEY='RWQfakepublickey'
export BACKFORT_FAKE_GPG_LOG="$TEST_DIRECTORY/gpg.log"
export BACKFORT_GPG_RECIPIENT_PRIMARY="$GPG_PRIMARY_FINGERPRINT"
export BACKFORT_GPG_RECIPIENT_RECOVERY="$GPG_RECOVERY_FINGERPRINT"
export BACKFORT_FAKE_GPG_AVAILABLE_RECIPIENTS="$GPG_PRIMARY_FINGERPRINT:$GPG_RECOVERY_FINGERPRINT"
export BACKFORT_GPG_IDENTITY_PASSWORD='test private-key passphrase'
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
grep -qx decrypt "$BACKFORT_FAKE_AGE_LOG"

printf 'tampered signature\n' >"$SIGNATURE_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job crypto --quick; then
  printf 'expected signature verification to fail after tampering\n' >&2
  exit 1
else
  VERIFY_RESULT=$?
fi
[[ $VERIFY_RESULT -eq 3 ]]

printf 'asymmetric gpg content\n' >"$GPG_SOURCE_DIRECTORY/important.txt"
cat >"$GPG_CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: gpg-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/gpg-backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$GPG_BACKUP_DIRECTORY"
jobs:
  - name: gpg-asymmetric
    source:
      type: files
      paths: ["$GPG_SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption:
      method: gpg
      recipients_env: [BACKFORT_GPG_RECIPIENT_PRIMARY, BACKFORT_GPG_RECIPIENT_RECOVERY]
      identity_password_env: BACKFORT_GPG_IDENTITY_PASSWORD
    retention: {keep_last: 1, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

"$PROJECT_DIRECTORY/backfort.sh" -c "$GPG_CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$GPG_CONFIG_FILE" run
[[ $(grep -c '^encrypt recipient=' "$BACKFORT_FAKE_GPG_LOG") -eq 2 ]]
grep -Fx "encrypt recipient=$GPG_PRIMARY_FINGERPRINT" "$BACKFORT_FAKE_GPG_LOG"
grep -Fx "encrypt recipient=$GPG_RECOVERY_FINGERPRINT" "$BACKFORT_FAKE_GPG_LOG"

GPG_BACKUP_ID=$(basename -- "$(find "$GPG_BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -print -quit)" .complete)
[[ -f $GPG_BACKUP_DIRECTORY/$GPG_BACKUP_ID.tar.gz.gpg ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$GPG_CONFIG_FILE" verify latest --job gpg-asymmetric --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$GPG_CONFIG_FILE" restore latest --job gpg-asymmetric --to "$GPG_RESTORE_DIRECTORY"
diff -r "$GPG_SOURCE_DIRECTORY" "$GPG_RESTORE_DIRECTORY$GPG_SOURCE_DIRECTORY"
[[ $(grep -c '^decrypt$' "$BACKFORT_FAKE_GPG_LOG") -eq 2 ]]

export BACKFORT_GPG_PASSWORD='test symmetric password'
cat >"$SYMMETRIC_GPG_CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: symmetric-gpg-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/symmetric-gpg.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$SYMMETRIC_GPG_BACKUP_DIRECTORY"
jobs:
  - name: gpg-symmetric
    source:
      type: files
      paths: ["$GPG_SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption:
      method: gpg
      password_env: BACKFORT_GPG_PASSWORD
    retention: {keep_last: 1, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

"$PROJECT_DIRECTORY/backfort.sh" -c "$SYMMETRIC_GPG_CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$SYMMETRIC_GPG_CONFIG_FILE" run
grep -Fx 'encrypt symmetric' "$BACKFORT_FAKE_GPG_LOG"
"$PROJECT_DIRECTORY/backfort.sh" -c "$SYMMETRIC_GPG_CONFIG_FILE" verify latest --job gpg-symmetric --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$SYMMETRIC_GPG_CONFIG_FILE" restore latest --job gpg-symmetric --to "$SYMMETRIC_GPG_RESTORE_DIRECTORY"
diff -r "$GPG_SOURCE_DIRECTORY" "$SYMMETRIC_GPG_RESTORE_DIRECTORY$GPG_SOURCE_DIRECTORY"

cat >"$INVALID_GPG_CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: invalid-gpg-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/invalid-gpg.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$GPG_BACKUP_DIRECTORY"
jobs:
  - name: invalid-gpg
    source:
      type: files
      paths: ["$GPG_SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption:
      method: gpg
      recipient_env: BACKFORT_GPG_RECIPIENT_PRIMARY
      password_env: BACKFORT_GPG_PASSWORD
    retention: {keep_last: 1, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

if "$PROJECT_DIRECTORY/backfort.sh" -c "$INVALID_GPG_CONFIG_FILE" doctor >"$TEST_DIRECTORY/invalid-gpg.log" 2>&1; then
  printf 'expected mixed GPG encryption configuration to fail\n' >&2
  exit 1
else
  INVALID_GPG_RESULT=$?
fi
[[ $INVALID_GPG_RESULT -eq 2 ]]
grep -q 'gpg-password-and-recipients-are-mutually-exclusive' "$TEST_DIRECTORY/invalid-gpg.log"

export BACKFORT_GPG_RECIPIENT_UNKNOWN='FEDCBA9876543210FEDCBA9876543210FEDCBA98'
cat >"$UNKNOWN_GPG_CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: unknown-gpg-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/unknown-gpg.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$GPG_BACKUP_DIRECTORY"
jobs:
  - name: unknown-gpg
    source:
      type: files
      paths: ["$GPG_SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption:
      method: gpg
      recipient_env: BACKFORT_GPG_RECIPIENT_UNKNOWN
    retention: {keep_last: 1, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

if "$PROJECT_DIRECTORY/backfort.sh" -c "$UNKNOWN_GPG_CONFIG_FILE" doctor >"$TEST_DIRECTORY/unknown-gpg.log" 2>&1; then
  printf 'expected unknown GPG recipient to fail doctor\n' >&2
  exit 1
else
  UNKNOWN_GPG_RESULT=$?
fi
[[ $UNKNOWN_GPG_RESULT -eq 2 ]]
grep -q 'gpg-recipient-key-not-available' "$TEST_DIRECTORY/unknown-gpg.log"

export BACKFORT_GPG_RECIPIENT_INVALID='not-a-fingerprint'
cp -- "$UNKNOWN_GPG_CONFIG_FILE" "$INVALID_GPG_FINGERPRINT_CONFIG_FILE"
sed -i 's/BACKFORT_GPG_RECIPIENT_UNKNOWN/BACKFORT_GPG_RECIPIENT_INVALID/' \
  "$INVALID_GPG_FINGERPRINT_CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$INVALID_GPG_FINGERPRINT_CONFIG_FILE" doctor >"$TEST_DIRECTORY/invalid-gpg-fingerprint.log" 2>&1; then
  printf 'expected malformed GPG fingerprint to fail doctor\n' >&2
  exit 1
else
  INVALID_GPG_FINGERPRINT_RESULT=$?
fi
[[ $INVALID_GPG_FINGERPRINT_RESULT -eq 2 ]]
grep -q 'invalid-gpg-fingerprint' "$TEST_DIRECTORY/invalid-gpg-fingerprint.log"

cp -- "$GPG_CONFIG_FILE" "$NON_GPG_IDENTITY_PASSWORD_CONFIG_FILE"
sed -i 's/method: gpg/method: age/' "$NON_GPG_IDENTITY_PASSWORD_CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$NON_GPG_IDENTITY_PASSWORD_CONFIG_FILE" doctor >"$TEST_DIRECTORY/non-gpg-identity-password.log" 2>&1; then
  printf 'expected non-GPG identity password setting to fail configuration\n' >&2
  exit 1
else
  NON_GPG_IDENTITY_PASSWORD_RESULT=$?
fi
[[ $NON_GPG_IDENTITY_PASSWORD_RESULT -eq 2 ]]
grep -q 'identity-password-requires-gpg-encryption' "$TEST_DIRECTORY/non-gpg-identity-password.log"

printf 'Backfort crypto smoke test passed.\n'
