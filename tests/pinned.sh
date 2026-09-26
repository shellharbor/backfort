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
PRIMARY_DIRECTORY="$TEST_DIRECTORY/primary"
REPLICA_DIRECTORY="$TEST_DIRECTORY/replica"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
RESTORE_DIRECTORY="$TEST_DIRECTORY/restore"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"

mkdir -p "$SOURCE_DIRECTORY" "$PRIMARY_DIRECTORY" "$REPLICA_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY"
printf 'pinned restore fixture\n' >"$SOURCE_DIRECTORY/important.txt"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: pinned-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: primary
    type: local
    path: "$PRIMARY_DIRECTORY"
  - name: replica
    type: local
    path: "$REPLICA_DIRECTORY"
jobs:
  - name: pinned
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [primary, replica]
    success: {min_copies: 1}
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 2, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

write_bundle() {
  local destination=$1
  local backup_id=$2
  local created_at=$3

  printf 'fixture payload\n' >"$destination/$backup_id.tar"
  printf 'fixture checksum\n' >"$destination/$backup_id.sha256"
  cat >"$destination/$backup_id.metadata.json" <<EOF
backup_id: "$backup_id"
job: pinned
created_at: "$created_at"
payload_file: "$backup_id.tar"
signing:
  method: none
EOF
  printf '%s\n' "$backup_id" >"$destination/$backup_id.complete"
}

write_incomplete_bundle() {
  local destination=$1
  local backup_id=$2

  printf 'incomplete payload\n' >"$destination/$backup_id.tar"
  printf 'incomplete checksum\n' >"$destination/$backup_id.sha256"
  cat >"$destination/$backup_id.metadata.json" <<EOF
backup_id: "$backup_id"
job: pinned
created_at: "2025-01-06T00:00:00Z"
payload_file: "$backup_id.tar"
signing:
  method: none
EOF
}

PINNED_ID='pinned-host_pinned_20250101T000000Z_00000001'
SECOND_ID='pinned-host_pinned_20250102T000000Z_00000002'
THIRD_ID='pinned-host_pinned_20250103T000000Z_00000003'
FOURTH_ID='pinned-host_pinned_20250104T000000Z_00000004'
FIFTH_ID='pinned-host_pinned_20250105T000000Z_00000005'
MIRROR_ID='pinned-host_pinned_20240101T000000Z_00000006'
INCOMPLETE_ID='pinned-host_pinned_20250106T000000Z_00000007'
ORPHAN_ID='pinned-host_pinned_20250107T000000Z_00000008'

write_bundle "$PRIMARY_DIRECTORY" "$PINNED_ID" '2025-01-01T00:00:00Z'
write_bundle "$PRIMARY_DIRECTORY" "$SECOND_ID" '2025-01-02T00:00:00Z'
write_bundle "$PRIMARY_DIRECTORY" "$THIRD_ID" '2025-01-03T00:00:00Z'
write_bundle "$PRIMARY_DIRECTORY" "$FOURTH_ID" '2025-01-04T00:00:00Z'
write_bundle "$PRIMARY_DIRECTORY" "$FIFTH_ID" '2025-01-05T00:00:00Z'
write_bundle "$REPLICA_DIRECTORY" "$PINNED_ID" '2025-01-01T00:00:00Z'

# No --from pins every completed copy and preserves an existing marker when
# the same reason is supplied again.
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" pin "$PINNED_ID" --reason 'pre-migration freeze'
[[ -f $PRIMARY_DIRECTORY/$PINNED_ID.pinned ]]
[[ -f $REPLICA_DIRECTORY/$PINNED_ID.pinned ]]
cp -- "$PRIMARY_DIRECTORY/$PINNED_ID.pinned" "$TEST_DIRECTORY/pinned-before"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" pin "$PINNED_ID" --reason 'pre-migration freeze' \
  >"$TEST_DIRECTORY/idempotent.stdout" 2>"$TEST_DIRECTORY/idempotent.stderr"
cmp -- "$TEST_DIRECTORY/pinned-before" "$PRIMARY_DIRECTORY/$PINNED_ID.pinned"
grep -Fq 'event=pin-already-pinned' "$TEST_DIRECTORY/idempotent.stderr"

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" list --json >"$TEST_DIRECTORY/list.json"
[[ $(yq eval '[.[] | select(has("pinned") | not)] | length' "$TEST_DIRECTORY/list.json") -eq 0 ]]
[[ $(yq eval ".[] | select(.backup_id == \"$PINNED_ID\" and .destination == \"primary\") | .pinned" "$TEST_DIRECTORY/list.json") == true ]]
[[ $(yq eval ".[] | select(.backup_id == \"$PINNED_ID\" and .destination == \"primary\") | .pinned_reason" "$TEST_DIRECTORY/list.json") == 'pre-migration freeze' ]]
[[ $(yq eval ".[] | select(.backup_id == \"$FIFTH_ID\" and .destination == \"primary\") | has(\"pinned_reason\")" "$TEST_DIRECTORY/list.json") == false ]]

# Pinned copies are reported separately in a plan and do not consume either
# of the two keep_last slots for unpinned copies.
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" prune --dry-run \
  >"$TEST_DIRECTORY/prune-plan.stdout" 2>"$TEST_DIRECTORY/prune-plan.stderr"
grep -Fq "backup_id=$PINNED_ID reason=pinned" "$TEST_DIRECTORY/prune-plan.stderr"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" prune
[[ -f $PRIMARY_DIRECTORY/$PINNED_ID.complete ]]
[[ -f $PRIMARY_DIRECTORY/$FOURTH_ID.complete ]]
[[ -f $PRIMARY_DIRECTORY/$FIFTH_ID.complete ]]
[[ ! -e $PRIMARY_DIRECTORY/$SECOND_ID.complete ]]
[[ ! -e $PRIMARY_DIRECTORY/$THIRD_ID.complete ]]

# A separately completed copy can be pinned and unpinned across both
# destinations without changing the protection on the old pre-migration copy.
write_bundle "$PRIMARY_DIRECTORY" "$MIRROR_ID" '2024-01-01T00:00:00Z'
write_bundle "$REPLICA_DIRECTORY" "$MIRROR_ID" '2024-01-01T00:00:00Z'
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" pin "$MIRROR_ID"
[[ -f $PRIMARY_DIRECTORY/$MIRROR_ID.pinned ]]
[[ -f $REPLICA_DIRECTORY/$MIRROR_ID.pinned ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" unpin "$MIRROR_ID" \
  >"$TEST_DIRECTORY/unpin.stdout" 2>"$TEST_DIRECTORY/unpin.stderr"
[[ ! -e $PRIMARY_DIRECTORY/$MIRROR_ID.pinned ]]
[[ ! -e $REPLICA_DIRECTORY/$MIRROR_ID.pinned ]]
grep -Fq "unpinned=$MIRROR_ID destinations=2" "$TEST_DIRECTORY/unpin.stderr"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" unpin "$MIRROR_ID" --from primary \
  >"$TEST_DIRECTORY/unpin-missing.stdout" 2>"$TEST_DIRECTORY/unpin-missing.stderr"; then
  printf 'expected unpin of an unpinned backup to fail\n' >&2
  exit 1
else
  UNPIN_MISSING_RESULT=$?
fi
[[ $UNPIN_MISSING_RESULT -eq 2 ]]
grep -Fq 'message=not-pinned' "$TEST_DIRECTORY/unpin-missing.stderr"

write_incomplete_bundle "$PRIMARY_DIRECTORY" "$INCOMPLETE_ID"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" pin "$INCOMPLETE_ID" --from primary \
  >"$TEST_DIRECTORY/incomplete-pin.stdout" 2>"$TEST_DIRECTORY/incomplete-pin.stderr"; then
  printf 'expected pin without a complete marker to fail\n' >&2
  exit 1
else
  INCOMPLETE_PIN_RESULT=$?
fi
[[ $INCOMPLETE_PIN_RESULT -eq 2 ]]
[[ ! -e $PRIMARY_DIRECTORY/$INCOMPLETE_ID.pinned ]]

# A real pinned archive restores normally; pin state is not part of payload
# validation or extraction.
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
RESTORE_ID=''
while IFS= read -r marker; do
  candidate=${marker%.complete}
  case "$candidate" in
    "$PINNED_ID"|"$SECOND_ID"|"$THIRD_ID"|"$FOURTH_ID"|"$FIFTH_ID"|"$MIRROR_ID") ;;
    *) RESTORE_ID=$candidate ;;
  esac
done < <(find "$PRIMARY_DIRECTORY" -maxdepth 1 -name '*.complete' -printf '%f\n')
[[ -n $RESTORE_ID ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" pin "$RESTORE_ID" --from primary
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" restore "$RESTORE_ID" --from primary --to "$RESTORE_DIRECTORY"
diff -r "$SOURCE_DIRECTORY" "$RESTORE_DIRECTORY$SOURCE_DIRECTORY"

# Orphan markers are warnings to doctor and are silently cleared by a real
# prune run. Dry-run remains read-only.
printf '2026-01-01T00:00:00Z orphaned\n' >"$PRIMARY_DIRECTORY/$ORPHAN_ID.pinned"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor \
  >"$TEST_DIRECTORY/doctor.stdout" 2>"$TEST_DIRECTORY/doctor.stderr"
grep -Fq "backup_id=$ORPHAN_ID message=orphaned-marker" "$TEST_DIRECTORY/doctor.stderr"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" prune
[[ ! -e $PRIMARY_DIRECTORY/$ORPHAN_ID.pinned ]]

# max_age_days is a hard expiry for ordinary copies, even when keep_last would
# retain them. Pins remain the explicit operator-controlled exception.
yq eval '.jobs[0].retention.keep_last = 99 | .jobs[0].retention.max_age_days = 1' -i "$CONFIG_FILE"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" prune --dry-run \
  >"$TEST_DIRECTORY/max-age-plan.stdout" 2>"$TEST_DIRECTORY/max-age-plan.stderr"
grep -Fq "backup_id=$MIRROR_ID reason=max-age" "$TEST_DIRECTORY/max-age-plan.stderr"
[[ -f $PRIMARY_DIRECTORY/$MIRROR_ID.complete && -f $REPLICA_DIRECTORY/$MIRROR_ID.complete ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" prune
[[ ! -e $PRIMARY_DIRECTORY/$MIRROR_ID.complete && ! -e $REPLICA_DIRECTORY/$MIRROR_ID.complete ]]
[[ -f $PRIMARY_DIRECTORY/$PINNED_ID.complete && -f $REPLICA_DIRECTORY/$PINNED_ID.complete ]]

# An explicit age expiry must be a positive integer; omission keeps GFS-only
# behavior for backwards-compatible configurations.
yq eval '.jobs[0].retention.max_age_days = 0' -i "$CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor \
  >"$TEST_DIRECTORY/max-age-invalid.stdout" 2>"$TEST_DIRECTORY/max-age-invalid.stderr"; then
  printf 'expected max_age_days=0 to fail validation\n' >&2
  exit 1
else
  MAX_AGE_INVALID_RESULT=$?
fi
[[ $MAX_AGE_INVALID_RESULT -eq 2 ]]
grep -Fq 'max-age-days-must-be-positive job=pinned' "$TEST_DIRECTORY/max-age-invalid.stderr"

printf 'Backfort pinned backup test passed.\n'
