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
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
TAMPER_DIRECTORY="$TEST_DIRECTORY/tamper"
LEGACY_DIRECTORY="$TEST_DIRECTORY/legacy"

mkdir -p "$SOURCE_DIRECTORY/nested" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY"
printf 'first protected file\n' >"$SOURCE_DIRECTORY/important.txt"
printf 'second protected file\n' >"$SOURCE_DIRECTORY/nested/notes.txt"
ln -s important.txt "$SOURCE_DIRECTORY/important-link"
ln "$SOURCE_DIRECTORY/important.txt" "$SOURCE_DIRECTORY/important-hardlink"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: hashes-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: hashes
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 4, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

write_payload_checksum() {
  local payload=$1
  local checksum_file=$2
  local checksum

  checksum=$(sha256sum "$payload" | awk '{print $1}')
  printf '%s  %s\n' "$checksum" "$(basename -- "$payload")" >"$checksum_file"
}

repack_with_manifest() {
  local payload=$1
  local unpacked=$2

  tar --create --file "$TAMPER_DIRECTORY/repacked.tar" --directory "$unpacked" data manifest.json
  gzip -c -- "$TAMPER_DIRECTORY/repacked.tar" >"$payload"
}

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run

BACKUP_ID=$(basename -- "$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -print -quit)" .complete)
PAYLOAD_FILE="$BACKUP_DIRECTORY/$BACKUP_ID.tar.gz"
METADATA_FILE="$BACKUP_DIRECTORY/$BACKUP_ID.metadata.json"
CHECKSUM_FILE="$BACKUP_DIRECTORY/$BACKUP_ID.sha256"
[[ $(yq eval -r '.file_hash_algorithm // ""' "$METADATA_FILE") == sha256 ]]

EXPECTED_PRIMARY_HASH=$(sha256sum "$SOURCE_DIRECTORY/important.txt" | awk '{print $1}')
EXPECTED_NESTED_HASH=$(sha256sum "$SOURCE_DIRECTORY/nested/notes.txt" | awk '{print $1}')
MANIFEST_HASHES=$(yq eval -r '.entries[] | select(.type == "file") | (.sha256 // "")' "$METADATA_FILE")
grep -Fx "$EXPECTED_PRIMARY_HASH" <<<"$MANIFEST_HASHES"
grep -Fx "$EXPECTED_NESTED_HASH" <<<"$MANIFEST_HASHES"
[[ $(grep -c '^[a-f0-9]\{64\}$' <<<"$MANIFEST_HASHES") -eq 2 ]]
[[ $(yq eval -r '.entries[] | select(.type == "symlink" or .type == "hardlink") | has("sha256")' "$METADATA_FILE" | sort -u) == false ]]

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job hashes --full

# Rebuild a structurally valid archive and checksum after changing one data
# file. Quick verification must still accept the outer payload checksum, while
# full verification must reject the manifest's per-file evidence.
mkdir -p "$TAMPER_DIRECTORY/unpacked"
gzip -dc -- "$PAYLOAD_FILE" >"$TAMPER_DIRECTORY/archive.tar"
tar --extract --file "$TAMPER_DIRECTORY/archive.tar" --directory "$TAMPER_DIRECTORY/unpacked"
printf 'tampered file with a valid outer archive\n' >"$TAMPER_DIRECTORY/unpacked/data$SOURCE_DIRECTORY/important.txt"
repack_with_manifest "$PAYLOAD_FILE" "$TAMPER_DIRECTORY/unpacked"
write_payload_checksum "$PAYLOAD_FILE" "$CHECKSUM_FILE"

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job hashes --quick
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job hashes --full >"$TEST_DIRECTORY/tampered-full-verify.log" 2>&1; then
  printf 'expected full verification to reject a changed archived file\n' >&2
  exit 1
else
  TAMPERED_VERIFY_RESULT=$?
fi
[[ $TAMPERED_VERIFY_RESULT -eq 3 ]]
grep -q 'file-hash-mismatch' "$TEST_DIRECTORY/tampered-full-verify.log"

# Older backups do not have file_hash_algorithm or per-file values. They retain
# the established archive-level full verification behavior.
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
LEGACY_BACKUP_ID=$(basename -- "$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' ! -name "$BACKUP_ID.complete" -print -quit)" .complete)
LEGACY_PAYLOAD_FILE="$BACKUP_DIRECTORY/$LEGACY_BACKUP_ID.tar.gz"
LEGACY_METADATA_FILE="$BACKUP_DIRECTORY/$LEGACY_BACKUP_ID.metadata.json"
LEGACY_CHECKSUM_FILE="$BACKUP_DIRECTORY/$LEGACY_BACKUP_ID.sha256"
mkdir -p "$LEGACY_DIRECTORY/unpacked"
gzip -dc -- "$LEGACY_PAYLOAD_FILE" >"$LEGACY_DIRECTORY/archive.tar"
tar --extract --file "$LEGACY_DIRECTORY/archive.tar" --directory "$LEGACY_DIRECTORY/unpacked"
yq eval -o=json 'del(.file_hash_algorithm) | del(.entries[].sha256)' "$LEGACY_METADATA_FILE" >"$LEGACY_DIRECTORY/manifest.json"
cp -- "$LEGACY_DIRECTORY/manifest.json" "$LEGACY_METADATA_FILE"
cp -- "$LEGACY_DIRECTORY/manifest.json" "$LEGACY_DIRECTORY/unpacked/manifest.json"
TAMPER_DIRECTORY="$LEGACY_DIRECTORY" repack_with_manifest "$LEGACY_PAYLOAD_FILE" "$LEGACY_DIRECTORY/unpacked"
write_payload_checksum "$LEGACY_PAYLOAD_FILE" "$LEGACY_CHECKSUM_FILE"
[[ $(yq eval -r '.file_hash_algorithm // ""' "$LEGACY_METADATA_FILE") == '' ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify "$LEGACY_BACKUP_ID" --full

printf 'Backfort file hash test passed.\n'
