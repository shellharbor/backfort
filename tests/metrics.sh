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
PARTIAL_BACKUP_DIRECTORY="$TEST_DIRECTORY/partial-backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
METRICS_DIRECTORY="$TEST_DIRECTORY/metrics"
RUNTIME_METRICS_DIRECTORY="$TEST_DIRECTORY/runtime-metrics"
BLOCKING_FILE="$TEST_DIRECTORY/not-a-directory"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
PARTIAL_CONFIG_FILE="$TEST_DIRECTORY/partial-config.yaml"
RUNTIME_CONFIG_FILE="$TEST_DIRECTORY/runtime-config.yaml"
BAD_CONFIG_FILE="$TEST_DIRECTORY/bad-config.yaml"
MALFORMED_CONFIG_FILE="$TEST_DIRECTORY/malformed-config.yaml"
MISSING_FIELD_CONFIG_FILE="$TEST_DIRECTORY/missing-field.yaml"
NONSTRING_DIRECTORY_CONFIG_FILE="$TEST_DIRECTORY/nonstring-directory.yaml"
MISSING_DIRECTORY_CONFIG_FILE="$TEST_DIRECTORY/missing-directory.yaml"
HOOK_SCRIPT="$TEST_DIRECTORY/make-metrics-unavailable"

mkdir -p \
  "$SOURCE_DIRECTORY" \
  "$BACKUP_DIRECTORY" \
  "$PARTIAL_BACKUP_DIRECTORY" \
  "$STATE_DIRECTORY" \
  "$TEMP_DIRECTORY" \
  "$METRICS_DIRECTORY" \
  "$RUNTIME_METRICS_DIRECTORY"
printf 'Prometheus metrics test payload\n' >"$SOURCE_DIRECTORY/data.txt"
printf 'not a directory\n' >"$BLOCKING_FILE"

write_config() {
  local output=$1
  local host=$2
  local job=$3
  local destination_block=$4
  local job_destinations=$5
  local metrics_directory=$6
  local hooks_block=${7:-}

  cat >"$output" <<EOF
version: 1
settings:
  host_id: $host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/$job.lock"
  min_free_mb: 1
metrics:
  prometheus:
    textfile_directory: "$metrics_directory"
destinations:
$destination_block
jobs:
  - name: $job
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
$hooks_block
    destinations: [$job_destinations]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 3, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF
}

LOCAL_DESTINATION=$(cat <<EOF
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
EOF
)
write_config "$CONFIG_FILE" metrics-host metrics "$LOCAL_DESTINATION" local "$METRICS_DIRECTORY"

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" --dry-run run
METRICS_FILE="$METRICS_DIRECTORY/backfort_metrics.prom"
[[ ! -e $METRICS_FILE ]]

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
[[ -f $METRICS_FILE && ! -L $METRICS_FILE ]]
[[ $(stat --format='%a' "$METRICS_FILE") == 644 ]]
grep -Fqx 'backfort_last_run_success{host="metrics-host",job="metrics"} 1' "$METRICS_FILE"
grep -Fqx 'backfort_last_run_exit_code{host="metrics-host",job="metrics"} 0' "$METRICS_FILE"
grep -Eq '^backfort_last_run_timestamp_seconds\{host="metrics-host",job="metrics"\} [1-9][0-9]*$' "$METRICS_FILE"
grep -Eq '^backfort_last_run_duration_seconds\{host="metrics-host",job="metrics"\} [0-9]+$' "$METRICS_FILE"
grep -Eq '^backfort_last_backup_size_bytes\{host="metrics-host",job="metrics"\} [1-9][0-9]*$' "$METRICS_FILE"
grep -Fqx 'backfort_last_successful_copies{host="metrics-host",job="metrics"} 1' "$METRICS_FILE"
grep -Fqx 'backfort_last_failed_copies{host="metrics-host",job="metrics"} 0' "$METRICS_FILE"
if grep -Fq "$SOURCE_DIRECTORY" "$METRICS_FILE"; then
  printf 'metric file leaked the source path\n' >&2
  exit 1
fi
if find "$METRICS_DIRECTORY" -maxdepth 1 -name '.backfort_metrics.prom.*' -print -quit | grep -q .; then
  printf 'metrics temporary file was not cleaned up\n' >&2
  exit 1
fi

PARTIAL_DESTINATIONS=$(cat <<EOF
  - name: good
    type: local
    path: "$PARTIAL_BACKUP_DIRECTORY"
  - name: blocked
    type: local
    path: "$BLOCKING_FILE/unavailable"
EOF
)
write_config "$PARTIAL_CONFIG_FILE" metrics-host metrics "$PARTIAL_DESTINATIONS" 'good, blocked' "$METRICS_DIRECTORY"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$PARTIAL_CONFIG_FILE" run; then
  printf 'expected partial backup run to return exit code 1\n' >&2
  exit 1
else
  PARTIAL_STATUS=$?
fi
[[ $PARTIAL_STATUS -eq 1 ]]
grep -Fqx 'backfort_last_run_success{host="metrics-host",job="metrics"} 0' "$METRICS_FILE"
grep -Fqx 'backfort_last_run_exit_code{host="metrics-host",job="metrics"} 1' "$METRICS_FILE"
grep -Fqx 'backfort_last_successful_copies{host="metrics-host",job="metrics"} 1' "$METRICS_FILE"
grep -Fqx 'backfort_last_failed_copies{host="metrics-host",job="metrics"} 1' "$METRICS_FILE"

cp -- "$CONFIG_FILE" "$BAD_CONFIG_FILE"
yq eval '.metrics.prometheus.unexpected = true' -i "$BAD_CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$BAD_CONFIG_FILE" doctor >"$TEST_DIRECTORY/bad.stderr" 2>&1; then
  printf 'expected unknown Prometheus key to be rejected\n' >&2
  exit 1
else
  BAD_STATUS=$?
fi
[[ $BAD_STATUS -eq 2 ]]
grep -Fq 'unknown-config-key path=.metrics.prometheus key=unexpected' "$TEST_DIRECTORY/bad.stderr"

cp -- "$CONFIG_FILE" "$MALFORMED_CONFIG_FILE"
yq eval '.metrics = []' -i "$MALFORMED_CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$MALFORMED_CONFIG_FILE" doctor >"$TEST_DIRECTORY/malformed.stderr" 2>&1; then
  printf 'expected non-map metrics configuration to be rejected\n' >&2
  exit 1
else
  MALFORMED_STATUS=$?
fi
[[ $MALFORMED_STATUS -eq 2 ]]
grep -Fq 'metrics-must-be-map' "$TEST_DIRECTORY/malformed.stderr"

cp -- "$CONFIG_FILE" "$MISSING_FIELD_CONFIG_FILE"
yq eval 'del(.metrics.prometheus.textfile_directory)' -i "$MISSING_FIELD_CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$MISSING_FIELD_CONFIG_FILE" doctor >"$TEST_DIRECTORY/missing-field.stderr" 2>&1; then
  printf 'expected missing textfile directory to be rejected\n' >&2
  exit 1
else
  MISSING_FIELD_STATUS=$?
fi
[[ $MISSING_FIELD_STATUS -eq 2 ]]
grep -Fq 'prometheus-textfile-directory-required' "$TEST_DIRECTORY/missing-field.stderr"

cp -- "$CONFIG_FILE" "$NONSTRING_DIRECTORY_CONFIG_FILE"
yq eval '.metrics.prometheus.textfile_directory = 42' -i "$NONSTRING_DIRECTORY_CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$NONSTRING_DIRECTORY_CONFIG_FILE" doctor >"$TEST_DIRECTORY/nonstring.stderr" 2>&1; then
  printf 'expected a non-string metrics directory to be rejected\n' >&2
  exit 1
else
  NONSTRING_STATUS=$?
fi
[[ $NONSTRING_STATUS -eq 2 ]]
grep -Fq 'prometheus-textfile-directory-must-be-string' "$TEST_DIRECTORY/nonstring.stderr"

write_config "$MISSING_DIRECTORY_CONFIG_FILE" metrics-host metrics "$LOCAL_DESTINATION" local "$TEST_DIRECTORY/missing-metrics"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$MISSING_DIRECTORY_CONFIG_FILE" doctor >"$TEST_DIRECTORY/missing.stderr" 2>&1; then
  printf 'expected doctor to reject a missing metrics directory\n' >&2
  exit 1
else
  MISSING_STATUS=$?
fi
[[ $MISSING_STATUS -eq 2 ]]
grep -Fq 'prometheus-textfile-directory-not-usable' "$TEST_DIRECTORY/missing.stderr"

cat >"$HOOK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

directory=$1
rmdir -- "$directory"
: >"$directory"
EOF
chmod 0700 "$HOOK_SCRIPT"
RUNTIME_HOOKS=$(cat <<EOF
    hooks:
      pre:
        path: "$HOOK_SCRIPT"
        args: ["$RUNTIME_METRICS_DIRECTORY"]
EOF
)
write_config "$RUNTIME_CONFIG_FILE" metrics-host runtime-metrics "$LOCAL_DESTINATION" local "$RUNTIME_METRICS_DIRECTORY" "$RUNTIME_HOOKS"
"$PROJECT_DIRECTORY/backfort.sh" -c "$RUNTIME_CONFIG_FILE" run >"$TEST_DIRECTORY/runtime.stdout" 2>"$TEST_DIRECTORY/runtime.stderr"
[[ -f $RUNTIME_METRICS_DIRECTORY ]]
grep -Fq 'kind=metrics message=prometheus-textfile-directory-not-usable' "$TEST_DIRECTORY/runtime.stderr"

printf 'Backfort Prometheus metrics test passed.\n'
