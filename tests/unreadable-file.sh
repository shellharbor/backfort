#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d)
CHANGER_PID=''

cleanup() {
  if [[ -n $CHANGER_PID ]]; then
    kill "$CHANGER_PID" >/dev/null 2>&1 || true
    wait "$CHANGER_PID" 2>/dev/null || true
  fi
  case "$TEST_DIRECTORY" in
    /tmp/*|/var/tmp/*) rm -rf -- "$TEST_DIRECTORY" ;;
  esac
}
trap cleanup EXIT

if ((EUID == 0)); then
  printf 'skip: this test needs a non-root user so chmod 000 genuinely blocks a read\n'
  exit 0
fi

SOURCE_DIRECTORY="$TEST_DIRECTORY/source"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
RESTORE_DIRECTORY="$TEST_DIRECTORY/restore"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: unreadable-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: files
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 10, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

run_backfort() {
  "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" "$@"
}

complete_count() {
  find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -type f | wc -l
}

# --- A: a permanently unreadable file must fail the job, not silently omit
# it from an archive that is still reported as a completed backup.
printf 'public\n' >"$SOURCE_DIRECTORY/public.txt"
printf 'private\n' >"$SOURCE_DIRECTORY/secret.txt"
chmod 000 "$SOURCE_DIRECTORY/secret.txt"
if run_backfort run >"$TEST_DIRECTORY/unreadable.out" 2>"$TEST_DIRECTORY/unreadable.err"; then
  printf 'expected an unreadable source file to fail the backup\n' >&2
  cat "$TEST_DIRECTORY/unreadable.err" >&2
  exit 1
else
  UNREADABLE_STATUS=$?
fi
[[ $UNREADABLE_STATUS -eq 3 ]]
grep -Fq 'kind=pack' "$TEST_DIRECTORY/unreadable.err"
grep -Fq 'message=tar-failed' "$TEST_DIRECTORY/unreadable.err"
if grep -Fq 'backup-succeeded' "$TEST_DIRECTORY/unreadable.err"; then
  printf 'a backup with an unreadable source file must never report success\n' >&2
  exit 1
fi
[[ $(complete_count) -eq 0 ]]
chmod 644 "$SOURCE_DIRECTORY/secret.txt"
rm -f -- "$SOURCE_DIRECTORY/secret.txt"

# --- B: a file that changes while being archived (tar exit status 1, "some
# files differ") is a tolerated race, not a read failure, and must still
# publish a complete backup with only a warning logged.
LIVE_FILE="$SOURCE_DIRECTORY/live-change.bin"
dd if=/dev/urandom of="$LIVE_FILE" bs=1M count=16 status=none
(
  while :; do
    touch -m "$LIVE_FILE"
    sleep 0.01
  done
) &
CHANGER_PID=$!
if ! run_backfort run >"$TEST_DIRECTORY/live-change.out" 2>"$TEST_DIRECTORY/live-change.err"; then
  cat "$TEST_DIRECTORY/live-change.err" >&2
  exit 1
fi
kill "$CHANGER_PID" >/dev/null 2>&1 || true
wait "$CHANGER_PID" 2>/dev/null || true
CHANGER_PID=''
grep -Fq 'message=source-files-changed-during-read' "$TEST_DIRECTORY/live-change.err"
grep -Fq 'event=backup-succeeded' "$TEST_DIRECTORY/live-change.err"
[[ $(complete_count) -eq 1 ]]
rm -f -- "$LIVE_FILE"

# --- C: a leading space in a file or directory name is not a parsing
# hazard (every archive member is transform-prefixed with the literal
# string "data", which never itself starts with whitespace) and must be
# archived and restored exactly, not silently dropped.
mkdir -p "$SOURCE_DIRECTORY/ leading-dir"
printf 'top-level leading space\n' >"$SOURCE_DIRECTORY/ leading-space.txt"
printf 'nested leading space\n' >"$SOURCE_DIRECTORY/ leading-dir/ nested.txt"
if ! run_backfort run >"$TEST_DIRECTORY/spaces.out" 2>"$TEST_DIRECTORY/spaces.err"; then
  cat "$TEST_DIRECTORY/spaces.err" >&2
  exit 1
fi
if grep -Fq 'unsupported-archive-member-removed' "$TEST_DIRECTORY/spaces.err"; then
  printf 'a leading-space name must not be treated as unsupported\n' >&2
  exit 1
fi
run_backfort restore latest --job files --to "$RESTORE_DIRECTORY" >/dev/null
[[ $(<"$RESTORE_DIRECTORY$SOURCE_DIRECTORY/ leading-space.txt") == 'top-level leading space' ]]
[[ $(<"$RESTORE_DIRECTORY$SOURCE_DIRECTORY/ leading-dir/ nested.txt") == 'nested leading space' ]]
rm -rf -- "$RESTORE_DIRECTORY" "$SOURCE_DIRECTORY/ leading-space.txt" "$SOURCE_DIRECTORY/ leading-dir"
COMPLETE_BEFORE_NEWLINE=$(complete_count)

# --- D: a name with a literal newline byte would corrupt Backfort's own
# line-oriented tar listings and YAML manifest. It is genuinely unsafe to
# include, so the job must fail outright instead of quietly publishing an
# archive that is missing that file.
newline_name=$'newline'$'\n'$'name.txt'
printf 'unsafe name\n' >"$SOURCE_DIRECTORY/$newline_name"
if run_backfort run >"$TEST_DIRECTORY/newline.out" 2>"$TEST_DIRECTORY/newline.err"; then
  printf 'expected a newline byte in a filename to fail the backup\n' >&2
  cat "$TEST_DIRECTORY/newline.err" >&2
  exit 1
else
  NEWLINE_STATUS=$?
fi
[[ $NEWLINE_STATUS -eq 3 ]]
grep -Fq 'message=unsupported-archive-member-removed' "$TEST_DIRECTORY/newline.err"
grep -Fq 'message=unsupported-entries-removed count=1' "$TEST_DIRECTORY/newline.err"
[[ $(complete_count) -eq $COMPLETE_BEFORE_NEWLINE ]]
if grep -Fq 'backup-succeeded' "$TEST_DIRECTORY/newline.err"; then
  printf 'a backup missing an unsupported member must never report success\n' >&2
  exit 1
fi
rm -f -- "$SOURCE_DIRECTORY/$newline_name"

printf 'Backfort unreadable and unsupported source file test passed.\n'
