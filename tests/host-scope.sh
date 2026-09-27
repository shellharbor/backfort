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
BACKUP_DIRECTORY="$TEST_DIRECTORY/shared-backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
HOST_A_CONFIG="$TEST_DIRECTORY/host-a.yaml"

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY"
printf 'host scope fixture\n' >"$SOURCE_DIRECTORY/file.txt"

cat >"$HOST_A_CONFIG" <<EOF
version: 1
settings:
  host_id: host-a
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: shared
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: app
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [shared]
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 1, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

write_bundle() {
  local backup_id=$1
  local created_at=$2

  printf 'fixture payload for %s\n' "$backup_id" >"$BACKUP_DIRECTORY/$backup_id.tar"
  printf 'fixture checksum\n' >"$BACKUP_DIRECTORY/$backup_id.sha256"
  cat >"$BACKUP_DIRECTORY/$backup_id.metadata.json" <<EOF
{
  "backup_id": "$backup_id",
  "job": "app",
  "created_at": "$created_at",
  "payload_file": "$backup_id.tar",
  "signing": {"method": "none"}
}
EOF
  printf '%s\n' "$backup_id" >"$BACKUP_DIRECTORY/$backup_id.complete"
}

HOST_A_OLD='host-a_app_20250101T000000Z_00000001'
HOST_A_NEW='host-a_app_20250201T000000Z_00000002'
HOST_B_FRESH="host-b_app_$(date -u +%Y%m%dT%H%M%SZ)_00000003"
write_bundle "$HOST_A_OLD" '2025-01-01T00:00:00Z'
write_bundle "$HOST_A_NEW" '2025-02-01T00:00:00Z'
write_bundle "$HOST_B_FRESH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A malformed marker belonging to the other host must not turn this host's
# maintenance command into an error before it reaches its own records.
printf '%s\n' 'foreign marker' >"$BACKUP_DIRECTORY/host-b_app_not-a-backup-id.complete"

LIST_OUTPUT=$("$PROJECT_DIRECTORY/backfort.sh" -c "$HOST_A_CONFIG" list --job app)
grep -Fq "$HOST_A_OLD" <<<"$LIST_OUTPUT"
grep -Fq "$HOST_A_NEW" <<<"$LIST_OUTPUT"
if grep -Fq 'host-b_app_' <<<"$LIST_OUTPUT"; then
  printf 'list leaked a different host into the current host scope\n' >&2
  exit 1
fi

STATUS_OUTPUT=$("$PROJECT_DIRECTORY/backfort.sh" -c "$HOST_A_CONFIG" status --job app)
grep -Fq "$HOST_A_NEW" <<<"$STATUS_OUTPUT"
if grep -Fq 'host-b_app_' <<<"$STATUS_OUTPUT"; then
  printf 'status selected a different host backup\n' >&2
  exit 1
fi

RESTORE_PLAN=$("$PROJECT_DIRECTORY/backfort.sh" -n -c "$HOST_A_CONFIG" \
  restore latest --job app --to "$TEST_DIRECTORY/restore-plan" 2>&1)
grep -Fq "backup_id=$HOST_A_NEW" <<<"$RESTORE_PLAN"
if grep -Fq 'host-b_app_' <<<"$RESTORE_PLAN"; then
  printf 'latest resolved a different host backup\n' >&2
  exit 1
fi

PICK_OUTPUT=$(printf 'q\n' | BACKFORT_TEST_ASSUME_TTY=1 "$PROJECT_DIRECTORY/backfort.sh" -c "$HOST_A_CONFIG" \
  restore --pick --job app --to "$TEST_DIRECTORY/restore-pick")
grep -Fq "$HOST_A_NEW" <<<"$PICK_OUTPUT"
if grep -Fq 'host-b_app_' <<<"$PICK_OUTPUT"; then
  printf 'restore --pick showed a different host backup\n' >&2
  exit 1
fi

# The newer backup from host-b is intentionally fresh. Watchdog must still
# report host-a stale because automatic discovery is host-scoped.
if "$PROJECT_DIRECTORY/backfort.sh" -c "$HOST_A_CONFIG" watchdog --max-age 1 \
  >"$TEST_DIRECTORY/watchdog.stdout" 2>"$TEST_DIRECTORY/watchdog.stderr"; then
  printf 'expected host-a watchdog to be stale despite host-b fresh backup\n' >&2
  exit 1
else
  WATCHDOG_RESULT=$?
fi
[[ $WATCHDOG_RESULT -eq 3 ]]
grep -Fq "backup_id=$HOST_A_NEW" "$TEST_DIRECTORY/watchdog.stderr"
if grep -Fq 'host-b_app_' "$TEST_DIRECTORY/watchdog.stderr"; then
  printf 'watchdog considered a different host backup\n' >&2
  exit 1
fi

"$PROJECT_DIRECTORY/backfort.sh" -c "$HOST_A_CONFIG" prune
[[ -f "$BACKUP_DIRECTORY/$HOST_B_FRESH.complete" ]]
[[ $(find "$BACKUP_DIRECTORY" -maxdepth 1 -name 'host-a_app_*.complete' -type f | wc -l) -eq 1 ]]

DELETE_PLAN=$("$PROJECT_DIRECTORY/backfort.sh" -c "$HOST_A_CONFIG" delete \
  --job app --since 2025-01-01 --until 2025-12-31 --dry-run 2>&1)
if grep -Fq 'host-b_app_' <<<"$DELETE_PLAN"; then
  printf 'date-range deletion considered a different host backup\n' >&2
  exit 1
fi
[[ -f "$BACKUP_DIRECTORY/$HOST_B_FRESH.complete" ]]

printf 'Backfort host scope test passed.\n'
