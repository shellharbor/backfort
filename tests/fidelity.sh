#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d /tmp/backfort-fidelity.XXXXXXXX)
CHANGER_PID=''

cleanup() {
  local result=$?

  trap - EXIT
  set +e

  if [[ -n $CHANGER_PID ]]; then
    kill "$CHANGER_PID" >/dev/null 2>&1 || true
    wait "$CHANGER_PID" 2>/dev/null || true
  fi

  case "$TEST_DIRECTORY" in
    /tmp/backfort-fidelity.*)
      if ((EUID == 0)); then
        rm -rf -- "$TEST_DIRECTORY"
      else
        sudo rm -rf -- "$TEST_DIRECTORY"
      fi
      ;;
    *)
      printf 'Refusing to remove unexpected test directory: %s\n' "$TEST_DIRECTORY" >&2
      ;;
  esac

  exit "$result"
}
trap cleanup EXIT

SOURCE_DIRECTORY="$TEST_DIRECTORY/source"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
RESTORE_DIRECTORY="$TEST_DIRECTORY/restore"
BIN_DIRECTORY="$TEST_DIRECTORY/bin"
TAR_LOG="$TEST_DIRECTORY/tar-create.log"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
REAL_TAR=$(command -v tar)

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY" "$BIN_DIRECTORY"
printf 'stable timestamp\n' >"$SOURCE_DIRECTORY/stable.txt"
truncate -s 16777216 "$SOURCE_DIRECTORY/sparse.bin"
printf 'backfort' | dd of="$SOURCE_DIRECTORY/sparse.bin" bs=1 seek=8388608 conv=notrunc status=none

cat >"$BIN_DIRECTORY/tar" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

for argument in "$@"; do
  if [[ $argument == --create ]]; then
    printf '%s\n' "$*" >>"$BACKFORT_TEST_TAR_LOG"
    break
  fi
done
exec "$BACKFORT_REAL_TAR" "$@"
EOF
chmod 0755 "$BIN_DIRECTORY/tar"
export BACKFORT_REAL_TAR="$REAL_TAR"
export BACKFORT_TEST_TAR_LOG="$TAR_LOG"
export PATH="$BIN_DIRECTORY:$PATH"

run_backfort() {
  if ((EUID == 0)); then
    "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" "$@"
  else
    sudo env "PATH=$PATH" BACKFORT_REAL_TAR="$BACKFORT_REAL_TAR" BACKFORT_TEST_TAR_LOG="$BACKFORT_TEST_TAR_LOG" \
      "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" "$@"
  fi
}

run_privileged() {
  if ((EUID == 0)); then
    "$@"
  else
    sudo env "PATH=$PATH" "$@"
  fi
}

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: fidelity-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: filesystem
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 4, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

# A root-operated recovery must retain the original numeric owner instead of
# silently changing every recovered file to root. ACL/xattr and sparse extent
# checks cover the GNU tar fidelity flags as observable behavior.
run_privileged chown 42424:42425 "$SOURCE_DIRECTORY/sparse.bin"
run_privileged setfattr -n user.backfort -v preserved "$SOURCE_DIRECTORY/sparse.bin"
run_privileged setfacl -m u:65534:r-- "$SOURCE_DIRECTORY/sparse.bin"
SOURCE_BLOCKS=$(stat --format=%b "$SOURCE_DIRECTORY/sparse.bin")

TZ=Pacific/Auckland run_backfort run
TZ=America/Los_Angeles run_backfort run
# GNU tar emits a "file changed as we read it" warning for live source data.
# --ignore-failed-read must keep that warning from discarding a complete
# version. A non-sparse fixture and frequent mtime changes make the warning
# observable without changing its content.
LIVE_FILE="$SOURCE_DIRECTORY/live-change.bin"
dd if=/dev/urandom of="$LIVE_FILE" bs=1M count=32 status=none
(
  while :; do
    touch -m "$LIVE_FILE"
    sleep 0.01
  done
) &
CHANGER_PID=$!
if ! TZ=UTC run_backfort run >"$TEST_DIRECTORY/live-change.out" 2>&1; then
  cat "$TEST_DIRECTORY/live-change.out" >&2
  exit 1
fi
kill "$CHANGER_PID" >/dev/null 2>&1 || true
wait "$CHANGER_PID" 2>/dev/null || true
CHANGER_PID=''
grep -q 'file changed as we read it' "$TEST_DIRECTORY/live-change.out"
run_backfort verify latest --job filesystem --full
run_backfort restore latest --job filesystem --to "$RESTORE_DIRECTORY"

RESTORED_SOURCE="$RESTORE_DIRECTORY$SOURCE_DIRECTORY"
RESTORED_FILE="$RESTORED_SOURCE/sparse.bin"
[[ $(run_privileged stat --format=%u:%g "$RESTORED_FILE") == 42424:42425 ]]
run_privileged getfattr --only-values -n user.backfort "$RESTORED_FILE" | grep -qx preserved
run_privileged getfacl --numeric --omit-header "$RESTORED_FILE" | grep -qx 'user:65534:r--'
RESTORED_BLOCKS=$(run_privileged stat --format=%b "$RESTORED_FILE")
((RESTORED_BLOCKS <= SOURCE_BLOCKS + 16))

# The tar listing is forced to UTC, so a host TZ change cannot turn unchanged
# files into noisy diff entries.
mapfile -t METADATA_FILES < <(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.metadata.json' -print | sort)
[[ ${#METADATA_FILES[@]} -eq 3 ]]
STABLE_MANIFEST_PATH="${SOURCE_DIRECTORY#/}/stable.txt"
MTIME_ONE=$(run_privileged env BF_STABLE_PATH="$STABLE_MANIFEST_PATH" yq eval -r '.entries[] | select(.path == strenv(BF_STABLE_PATH)) | .mtime' "${METADATA_FILES[0]}")
MTIME_TWO=$(run_privileged env BF_STABLE_PATH="$STABLE_MANIFEST_PATH" yq eval -r '.entries[] | select(.path == strenv(BF_STABLE_PATH)) | .mtime' "${METADATA_FILES[1]}")
[[ -n $MTIME_ONE && $MTIME_ONE == "$MTIME_TWO" ]]

# Backfort runs the archive process with a restrictive umask, so this trace is
# root-owned when the test exercises privileged ownership restoration.
run_privileged grep -q -- '--xattrs' "$TAR_LOG"
run_privileged grep -q -- '--acls' "$TAR_LOG"
run_privileged grep -q -- '--sparse' "$TAR_LOG"
run_privileged grep -q -- '--ignore-failed-read' "$TAR_LOG"

printf 'Backfort restore fidelity test passed.\n'
