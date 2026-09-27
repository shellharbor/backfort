#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d)

cleanup() {
  gpgconf --homedir "$WRITER_GNUPGHOME" --kill gpg-agent >/dev/null 2>&1 || true
  gpgconf --homedir "$RECOVERY_GNUPGHOME" --kill gpg-agent >/dev/null 2>&1 || true
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
SYMMETRIC_BACKUP_DIRECTORY="$TEST_DIRECTORY/symmetric-backups"
SYMMETRIC_RESTORE_DIRECTORY="$TEST_DIRECTORY/symmetric-restore"
SYMMETRIC_CONFIG_FILE="$TEST_DIRECTORY/symmetric-config.yaml"
WRITER_GNUPGHOME="$TEST_DIRECTORY/writer-gnupg"
RECOVERY_GNUPGHOME="$TEST_DIRECTORY/recovery-gnupg"
PUBLIC_KEY_FILE="$TEST_DIRECTORY/recovery-public.asc"
PASSPHRASE='backfort-test-private-key-passphrase'

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY" \
  "$SYMMETRIC_BACKUP_DIRECTORY" "$WRITER_GNUPGHOME" "$RECOVERY_GNUPGHOME"
chmod 0700 "$WRITER_GNUPGHOME" "$RECOVERY_GNUPGHOME"
printf 'real asymmetric gpg content\n' >"$SOURCE_DIRECTORY/important.txt"

export GNUPGHOME="$RECOVERY_GNUPGHOME"
gpg --batch --yes --pinentry-mode loopback --passphrase "$PASSPHRASE" \
  --quick-generate-key 'Backfort recovery test <recovery@example.test>' default default never
RECIPIENT_FINGERPRINT=$(gpg --batch --with-colons --list-keys 'recovery@example.test' \
  | awk -F: '$1 == "fpr" { print $10; exit }')
RECIPIENT_SUBKEY_FINGERPRINT=$(gpg --batch --with-colons --list-keys 'recovery@example.test' \
  | awk -F: '$1 == "sub" { subkey = 1; next } subkey && $1 == "fpr" { print $10; exit }')
[[ $RECIPIENT_FINGERPRINT =~ ^[A-Fa-f0-9]{40}$ || $RECIPIENT_FINGERPRINT =~ ^[A-Fa-f0-9]{64}$ ]]
[[ $RECIPIENT_SUBKEY_FINGERPRINT =~ ^[A-Fa-f0-9]{40}$ || $RECIPIENT_SUBKEY_FINGERPRINT =~ ^[A-Fa-f0-9]{64}$ ]]
gpg --batch --yes --armor --output "$PUBLIC_KEY_FILE" --export "$RECIPIENT_FINGERPRINT"

export GNUPGHOME="$WRITER_GNUPGHOME"
gpg --batch --import "$PUBLIC_KEY_FILE"
if gpg --batch --with-colons --list-secret-keys "$RECIPIENT_FINGERPRINT" 2>/dev/null | grep -q '^sec:'; then
  printf 'writer keyring must not contain the recovery private key\n' >&2
  exit 1
fi

export BACKFORT_GPG_RECIPIENT="$RECIPIENT_FINGERPRINT"
cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: gpg-integration-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: gpg-integration
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption:
      method: gpg
      recipient_env: BACKFORT_GPG_RECIPIENT
      identity_password_env: BACKFORT_GPG_IDENTITY_PASSWORD
    retention: {keep_last: 1, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
BACKUP_ID=$(basename -- "$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -print -quit)" .complete)
[[ -f $BACKUP_DIRECTORY/$BACKUP_ID.tar.gz.gpg ]]

# Even with the private-key passphrase available, a writer that imported only a
# public key must not be able to decrypt its own backup.
export BACKFORT_GPG_IDENTITY_PASSWORD="$PASSPHRASE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job gpg-integration --full >"$TEST_DIRECTORY/writer-full-verify.log" 2>&1; then
  printf 'expected public-key-only writer to fail full verification\n' >&2
  exit 1
else
  WRITER_FULL_VERIFY_RESULT=$?
fi
[[ $WRITER_FULL_VERIFY_RESULT -eq 3 ]]
grep -q 'archive-stream-failed' "$TEST_DIRECTORY/writer-full-verify.log"
unset BACKFORT_GPG_IDENTITY_PASSWORD

export GNUPGHOME="$RECOVERY_GNUPGHOME"
export BACKFORT_GPG_IDENTITY_PASSWORD="$PASSPHRASE"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job gpg-integration --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" restore latest --job gpg-integration --to "$RESTORE_DIRECTORY"
diff -r "$SOURCE_DIRECTORY" "$RESTORE_DIRECTORY$SOURCE_DIRECTORY"

# Symmetric GPG uses the same pipe-backed passphrase path. This exercises real
# GnuPG encryption, full verification, and restore instead of only a fake
# command adapter.
export BACKFORT_GPG_PASSWORD="$PASSPHRASE"
cat >"$SYMMETRIC_CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: gpg-symmetric-integration-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/symmetric-backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$SYMMETRIC_BACKUP_DIRECTORY"
jobs:
  - name: gpg-symmetric-integration
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
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

"$PROJECT_DIRECTORY/backfort.sh" -c "$SYMMETRIC_CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$SYMMETRIC_CONFIG_FILE" run
"$PROJECT_DIRECTORY/backfort.sh" -c "$SYMMETRIC_CONFIG_FILE" verify latest --job gpg-symmetric-integration --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$SYMMETRIC_CONFIG_FILE" restore latest --job gpg-symmetric-integration --to "$SYMMETRIC_RESTORE_DIRECTORY"
diff -r "$SOURCE_DIRECTORY" "$SYMMETRIC_RESTORE_DIRECTORY$SOURCE_DIRECTORY"
unset BACKFORT_GPG_PASSWORD

if grep -Fq '3<<<' "$PROJECT_DIRECTORY/backfort.sh"; then
  printf 'GPG passphrases must not use a Bash here-string\n' >&2
  exit 1
fi

export GNUPGHOME="$WRITER_GNUPGHOME"
export BACKFORT_GPG_RECIPIENT="$RECIPIENT_SUBKEY_FINGERPRINT"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor >"$TEST_DIRECTORY/subkey-recipient.log" 2>&1; then
  printf 'expected GPG subkey fingerprint to fail doctor\n' >&2
  exit 1
else
  SUBKEY_RECIPIENT_RESULT=$?
fi
[[ $SUBKEY_RECIPIENT_RESULT -eq 2 ]]
grep -q 'gpg-recipient-key-not-available' "$TEST_DIRECTORY/subkey-recipient.log"

printf 'Backfort asymmetric GPG integration test passed.\n'
