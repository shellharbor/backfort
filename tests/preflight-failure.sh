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
MISSING_SOURCE_DIRECTORY="$TEST_DIRECTORY/missing-source"
COMPOSE_DIRECTORY="$TEST_DIRECTORY/compose"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
METRICS_DIRECTORY="$TEST_DIRECTORY/metrics"
FAKE_DOCKER_ROOT="$TEST_DIRECTORY/fake-docker"
NOTIFICATION_DIRECTORY="$TEST_DIRECTORY/notifications"
BIN_DIRECTORY="$TEST_DIRECTORY/bin"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
MISSING_METRICS_CONFIG_FILE="$TEST_DIRECTORY/missing-metrics-config.yaml"

mkdir -p \
  "$SOURCE_DIRECTORY" \
  "$COMPOSE_DIRECTORY" \
  "$BACKUP_DIRECTORY" \
  "$STATE_DIRECTORY" \
  "$TEMP_DIRECTORY" \
  "$METRICS_DIRECTORY" \
  "$FAKE_DOCKER_ROOT" \
  "$NOTIFICATION_DIRECTORY" \
  "$BIN_DIRECTORY"
printf 'healthy preflight fixture\n' >"$SOURCE_DIRECTORY/data.txt"
cat >"$COMPOSE_DIRECTORY/compose.yaml" <<'EOF'
services:
  postgres: {image: postgres:17}
EOF

ln -s "$PROJECT_DIRECTORY/tests/fake-docker.sh" "$BIN_DIRECTORY/docker"
cat >"$BIN_DIRECTORY/curl" <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

: "${BACKFORT_TEST_NOTIFICATION_DIRECTORY:?missing output directory}"
body=''
previous=''
for argument in "$@"; do
  if [[ $previous == --data-binary ]]; then
    body=${argument#@}
    break
  fi
  previous=$argument
done
[[ -n $body && -f $body ]] || exit 64
request=$(mktemp "$BACKFORT_TEST_NOTIFICATION_DIRECTORY/request.XXXXXXXX")
cp -- "$body" "$request"
printf '{"ok":true}\n'
EOF
chmod 0700 "$BIN_DIRECTORY/curl"

export BACKFORT_FAKE_DOCKER_ROOT="$FAKE_DOCKER_ROOT"
export BACKFORT_FAKE_DOCKER_LOG="$TEST_DIRECTORY/docker.log"
export BACKFORT_TEST_NOTIFICATION_DIRECTORY="$NOTIFICATION_DIRECTORY"
export BACKFORT_PREFLIGHT_WEBHOOK_URL='https://monitoring.example.test/backfort'
export PATH="$BIN_DIRECTORY:$PATH"
unset BACKFORT_PREFLIGHT_DB_PASSWORD || true

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: preflight-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
metrics:
  prometheus:
    textfile_directory: "$METRICS_DIRECTORY"
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: missing-source
    source:
      type: files
      paths: ["$MISSING_SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 3, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
  - name: compose-password
    source:
      type: docker_compose
      project_dir: "$COMPOSE_DIRECTORY"
      files: [compose.yaml]
      volumes: []
      bind_mounts: []
      databases:
        - name: postgres
          service: postgres
          engine: postgres
          user: backfort
          password_env: BACKFORT_PREFLIGHT_DB_PASSWORD
          databases: [app]
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 3, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
  - name: healthy
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 3, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
notifications:
  enabled: true
  defaults: {events: [failure], antiflood_hours: 1}
  channels:
    - name: preflight-webhook
      type: webhook
      url_env: BACKFORT_PREFLIGHT_WEBHOOK_URL
      events: [failure]
EOF

if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >"$TEST_DIRECTORY/run.out" 2>"$TEST_DIRECTORY/run.err"; then
  printf 'expected run to report preflight failures\n' >&2
  exit 1
else
  RUN_STATUS=$?
fi
[[ $RUN_STATUS -eq 3 ]]
grep -Fq 'source-does-not-exist job=missing-source' "$TEST_DIRECTORY/run.err"
grep -Fq 'missing-environment-variable job=compose-password variable=BACKFORT_PREFLIGHT_DB_PASSWORD' "$TEST_DIRECTORY/run.err"

for job in missing-source compose-password; do
  METRICS_FILE="$METRICS_DIRECTORY/backfort_${job}.prom"
  [[ -f $METRICS_FILE && ! -L $METRICS_FILE ]]
  grep -Fqx "backfort_last_run_success{host=\"preflight-host\",job=\"$job\"} 0" "$METRICS_FILE"
  grep -Fqx "backfort_last_run_exit_code{host=\"preflight-host\",job=\"$job\"} 3" "$METRICS_FILE"
  grep -Fqx "backfort_last_run_duration_seconds{host=\"preflight-host\",job=\"$job\"} 0" "$METRICS_FILE"
  grep -Fqx "backfort_last_backup_size_bytes{host=\"preflight-host\",job=\"$job\"} 0" "$METRICS_FILE"
  grep -Fqx "backfort_last_successful_copies{host=\"preflight-host\",job=\"$job\"} 0" "$METRICS_FILE"
  grep -Fqx "backfort_last_failed_copies{host=\"preflight-host\",job=\"$job\"} 0" "$METRICS_FILE"
done

HEALTHY_METRICS_FILE="$METRICS_DIRECTORY/backfort_healthy.prom"
grep -Fqx 'backfort_last_run_success{host="preflight-host",job="healthy"} 1' "$HEALTHY_METRICS_FILE"
grep -Fqx 'backfort_last_run_exit_code{host="preflight-host",job="healthy"} 0' "$HEALTHY_METRICS_FILE"
find "$BACKUP_DIRECTORY" -maxdepth 1 -name 'preflight-host_healthy_*.complete' -print -quit | grep -q .
if find "$BACKUP_DIRECTORY" -maxdepth 1 -name 'preflight-host_missing-source_*' -print -quit | grep -q . \
  || find "$BACKUP_DIRECTORY" -maxdepth 1 -name 'preflight-host_compose-password_*' -print -quit | grep -q .; then
  printf 'a failed preflight published a backup artifact\n' >&2
  exit 1
fi

[[ $(find "$NOTIFICATION_DIRECTORY" -maxdepth 1 -name 'request.*' -type f | wc -l) -eq 2 ]]
for request in "$NOTIFICATION_DIRECTORY"/request.*; do
  yq eval -e '.event == "failure" and .data.stage == "preflight" and .data.error == "job preflight failed; see Backfort log"' "$request" >/dev/null
done
yq eval -N -r '.data.job' "$NOTIFICATION_DIRECTORY"/request.* | sort | diff -u <(printf '%s\n' compose-password missing-source) -

# The isolated run path changes only `run`: doctor remains deliberately strict.
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor --job compose-password >"$TEST_DIRECTORY/doctor.out" 2>"$TEST_DIRECTORY/doctor.err"; then
  printf 'expected doctor to reject the missing database password environment variable\n' >&2
  exit 1
else
  DOCTOR_STATUS=$?
fi
[[ $DOCTOR_STATUS -eq 2 ]]
grep -Fq 'missing-environment-variable job=compose-password variable=BACKFORT_PREFLIGHT_DB_PASSWORD' "$TEST_DIRECTORY/doctor.err"
[[ $(find "$NOTIFICATION_DIRECTORY" -maxdepth 1 -name 'request.*' -type f | wc -l) -eq 2 ]]

# The collector itself cannot receive a metric, but it still creates an alert
# for each selected job and prevents an unobserved backup attempt.
cp -- "$CONFIG_FILE" "$MISSING_METRICS_CONFIG_FILE"
BACKFORT_TEST_MISSING_METRICS_DIRECTORY="$TEST_DIRECTORY/missing-metrics" \
  yq eval '.metrics.prometheus.textfile_directory = strenv(BACKFORT_TEST_MISSING_METRICS_DIRECTORY)' -i "$MISSING_METRICS_CONFIG_FILE"
HEALTHY_BACKUP_COUNT=$(find "$BACKUP_DIRECTORY" -maxdepth 1 -name 'preflight-host_healthy_*.complete' -type f | wc -l)
if "$PROJECT_DIRECTORY/backfort.sh" -c "$MISSING_METRICS_CONFIG_FILE" run --job healthy >"$TEST_DIRECTORY/missing-metrics.out" 2>"$TEST_DIRECTORY/missing-metrics.err"; then
  printf 'expected run to reject an unusable Prometheus collector directory\n' >&2
  exit 1
else
  MISSING_METRICS_STATUS=$?
fi
[[ $MISSING_METRICS_STATUS -eq 3 ]]
grep -Fq 'prometheus-textfile-directory-not-usable' "$TEST_DIRECTORY/missing-metrics.err"
[[ $(find "$BACKUP_DIRECTORY" -maxdepth 1 -name 'preflight-host_healthy_*.complete' -type f | wc -l) -eq "$HEALTHY_BACKUP_COUNT" ]]
[[ $(find "$NOTIFICATION_DIRECTORY" -maxdepth 1 -name 'request.*' -type f | wc -l) -eq 3 ]]
METRICS_PREFLIGHT_ALERT=false
for request in "$NOTIFICATION_DIRECTORY"/request.*; do
  if [[ $(yq eval '.event == "failure" and .data.job == "healthy" and .data.stage == "preflight" and .data.error == "Prometheus metrics preflight failed; see Backfort log"' "$request") == true ]]; then
    METRICS_PREFLIGHT_ALERT=true
  fi
done
[[ $METRICS_PREFLIGHT_ALERT == true ]]

printf 'Backfort preflight failure test passed.\n'
