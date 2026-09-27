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
HOOK_SCRIPT="$TEST_DIRECTORY/backfort-hook"
HOOK_LOG="$TEST_DIRECTORY/hooks.log"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
PRE_FAILURE_CONFIG="$TEST_DIRECTORY/pre-failure.yaml"
POST_FAILURE_CONFIG="$TEST_DIRECTORY/post-failure.yaml"
UNSAFE_CONFIG="$TEST_DIRECTORY/unsafe.yaml"

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY"
printf 'hook test payload\n' >"$SOURCE_DIRECTORY/data.txt"

cat >"$HOOK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

log_file=$1
behavior=$2

[[ -z ${BACKFORT_TEST_HOOK_SECRET+x} ]] || exit 91
[[ $PWD == / ]] || exit 92
[[ $BACKFORT_HOOK_CONFIG_FILE == /* ]] || exit 93
printf '%s|%s|%s|%s|%s|%s\n' \
  "$BACKFORT_HOOK_PHASE" \
  "$BACKFORT_HOOK_JOB" \
  "$BACKFORT_HOOK_BACKUP_ID" \
  "$BACKFORT_HOOK_RESULT" \
  "$BACKFORT_HOOK_EXIT_CODE" \
  "$PWD" >>"$log_file"

case "$BACKFORT_HOOK_PHASE:$behavior" in
  pre:fail-pre) exit 12 ;;
  post:fail-post) exit 13 ;;
esac
EOF
chmod 0700 "$HOOK_SCRIPT"

write_config() {
  local output=$1
  local pre_behavior=$2
  local post_behavior=$3

  cat >"$output" <<EOF
version: 1
settings:
  host_id: hooks-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: hooks
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 3, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
    hooks:
      pre:
        path: "$HOOK_SCRIPT"
        args: ["$HOOK_LOG", "$pre_behavior"]
      post:
        path: "$HOOK_SCRIPT"
        args: ["$HOOK_LOG", "$post_behavior"]
EOF
}

write_config "$CONFIG_FILE" normal normal
export BACKFORT_TEST_HOOK_SECRET='must-not-reach-the-hook'

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" --dry-run run >"$TEST_DIRECTORY/dry-run.log" 2>&1
[[ ! -e $HOOK_LOG ]]
grep -q 'event=plan-hook job=hooks phase=pre' "$TEST_DIRECTORY/dry-run.log"
grep -q 'event=plan-hook job=hooks phase=post' "$TEST_DIRECTORY/dry-run.log"

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
[[ $(wc -l <"$HOOK_LOG") -eq 2 ]]
PRE_ID=$(awk -F '|' 'NR == 1 { print $3 }' "$HOOK_LOG")
POST_ID=$(awk -F '|' 'NR == 2 { print $3 }' "$HOOK_LOG")
[[ $PRE_ID == "$POST_ID" ]]
[[ $(awk -F '|' 'NR == 1 { print $1 ":" $2 ":" $4 ":" $5 ":" $6 }' "$HOOK_LOG") == 'pre:hooks:starting:0:/' ]]
[[ $(awk -F '|' 'NR == 2 { print $1 ":" $2 ":" $4 ":" $5 ":" $6 }' "$HOOK_LOG") == 'post:hooks:success:0:/' ]]

BASELINE_COPIES=$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' | wc -l)
rm -f -- "$HOOK_LOG"
write_config "$PRE_FAILURE_CONFIG" fail-pre normal
if "$PROJECT_DIRECTORY/backfort.sh" -c "$PRE_FAILURE_CONFIG" run; then
  printf 'expected failed pre hook to stop the backup\n' >&2
  exit 1
else
  PRE_FAILURE_STATUS=$?
fi
[[ $PRE_FAILURE_STATUS -eq 3 ]]
[[ $(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' | wc -l) -eq "$BASELINE_COPIES" ]]
[[ $(wc -l <"$HOOK_LOG") -eq 2 ]]
[[ $(awk -F '|' 'NR == 1 { print $1 ":" $4 ":" $5 }' "$HOOK_LOG") == 'pre:starting:0' ]]
[[ $(awk -F '|' 'NR == 2 { print $1 ":" $4 ":" $5 }' "$HOOK_LOG") == 'post:failure:3' ]]

rm -f -- "$HOOK_LOG"
write_config "$POST_FAILURE_CONFIG" normal fail-post
if "$PROJECT_DIRECTORY/backfort.sh" -c "$POST_FAILURE_CONFIG" run; then
  printf 'expected failed post hook to fail the job result\n' >&2
  exit 1
else
  POST_FAILURE_STATUS=$?
fi
[[ $POST_FAILURE_STATUS -eq 3 ]]
[[ $(find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' | wc -l) -eq $((BASELINE_COPIES + 1)) ]]
[[ $(awk -F '|' 'NR == 2 { print $1 ":" $4 ":" $5 }' "$HOOK_LOG") == 'post:success:0' ]]

chmod 0770 "$HOOK_SCRIPT"
write_config "$UNSAFE_CONFIG" normal normal
if "$PROJECT_DIRECTORY/backfort.sh" -c "$UNSAFE_CONFIG" doctor >"$TEST_DIRECTORY/unsafe.log" 2>&1; then
  printf 'expected doctor to reject a group-writable hook\n' >&2
  exit 1
else
  UNSAFE_STATUS=$?
fi
[[ $UNSAFE_STATUS -eq 2 ]]
grep -q 'hook-group-or-other-writable' "$TEST_DIRECTORY/unsafe.log"

printf 'Backfort hooks test passed.\n'
