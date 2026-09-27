#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d /tmp/backfort-compose-real.XXXXXXXX)
RUN_ID="backfort-real-${RANDOM}-$$"
SOURCE_PROJECT="$TEST_DIRECTORY/source-$RUN_ID"
TARGET_PROJECT="$TEST_DIRECTORY/target-$RUN_ID"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
STAGING_DIRECTORY="$TEST_DIRECTORY/staging"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
VOLUME_HELPER_IMAGE=debian:bookworm-slim
POSTGRES_PASSWORD="backfort-test-postgres-${RANDOM}"
MYSQL_PASSWORD="backfort-test-mysql-${RANDOM}"

compose_at() {
  local project_directory=$1
  shift
  docker compose --project-directory "$project_directory" \
    -f "$project_directory/compose.yaml" "$@"
}

cleanup() {
  local result=$?

  trap - EXIT
  set +e
  if [[ -d ${TARGET_PROJECT:-} ]]; then
    compose_at "$TARGET_PROJECT" down --volumes --remove-orphans >/dev/null 2>&1
  fi
  if [[ -d ${SOURCE_PROJECT:-} ]]; then
    compose_at "$SOURCE_PROJECT" down --volumes --remove-orphans >/dev/null 2>&1
  fi
  case "$TEST_DIRECTORY" in
    /tmp/backfort-compose-real.*) rm -rf -- "$TEST_DIRECTORY" ;;
    *) printf 'refusing to remove unexpected test directory: %s\n' "$TEST_DIRECTORY" >&2 ;;
  esac
  exit "$result"
}
trap cleanup EXIT

wait_for_postgres() {
  local project_directory=$1
  local attempt

  for ((attempt = 1; attempt <= 60; attempt++)); do
    if compose_at "$project_directory" exec -T postgres \
      pg_isready --username backfort --dbname crm >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  printf 'PostgreSQL did not become ready: %s\n' "$project_directory" >&2
  return 1
}

wait_for_mysql() {
  local project_directory=$1
  local attempt

  for ((attempt = 1; attempt <= 60; attempt++)); do
    if compose_at "$project_directory" exec -T -e "MYSQL_PWD=$MYSQL_PASSWORD" mysql \
      mysql --protocol=TCP --host=127.0.0.1 --batch --skip-column-names \
        --user=backfort -e 'SELECT 1' 2>/dev/null | grep -qx 1; then
      return 0
    fi
    sleep 2
  done
  printf 'MySQL did not become ready: %s\n' "$project_directory" >&2
  return 1
}

mkdir -p -- "$SOURCE_PROJECT" "$TARGET_PROJECT" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" \
  "$TEMP_DIRECTORY"

cat >"$SOURCE_PROJECT/compose.yaml" <<EOF
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: crm
      POSTGRES_USER: backfort
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
  mysql:
    image: mysql:8.4
    environment:
      MYSQL_DATABASE: crm
      MYSQL_USER: backfort
      MYSQL_PASSWORD: $MYSQL_PASSWORD
      MYSQL_ROOT_PASSWORD: root-$MYSQL_PASSWORD
  evidence:
    image: debian:bookworm-slim
    command: ["sh", "-c", "sleep infinity"]
    volumes:
      - evidence:/evidence
volumes:
  evidence: {}
EOF
cp -- "$SOURCE_PROJECT/compose.yaml" "$TARGET_PROJECT/compose.yaml"

export BACKFORT_REAL_POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
export BACKFORT_REAL_MYSQL_PASSWORD="$MYSQL_PASSWORD"

docker image inspect "$VOLUME_HELPER_IMAGE" >/dev/null 2>&1 \
  || docker pull "$VOLUME_HELPER_IMAGE" >/dev/null
compose_at "$SOURCE_PROJECT" up --detach
compose_at "$TARGET_PROJECT" up --detach postgres mysql
wait_for_postgres "$SOURCE_PROJECT"
wait_for_mysql "$SOURCE_PROJECT"
wait_for_postgres "$TARGET_PROJECT"
wait_for_mysql "$TARGET_PROJECT"

compose_at "$SOURCE_PROJECT" exec -T postgres \
  psql --set=ON_ERROR_STOP=1 --username backfort --dbname crm <<'SQL'
CREATE TABLE recovery_probe (id integer PRIMARY KEY, marker text NOT NULL);
INSERT INTO recovery_probe (id, marker) VALUES (1, 'postgres-live-roundtrip');
SQL
compose_at "$SOURCE_PROJECT" exec -T -e "MYSQL_PWD=$MYSQL_PASSWORD" mysql \
  mysql --protocol=TCP --host=127.0.0.1 --user=backfort crm <<'SQL'
CREATE TABLE recovery_probe (id INT PRIMARY KEY, marker VARCHAR(255) NOT NULL);
INSERT INTO recovery_probe (id, marker) VALUES (1, 'mysql-live-roundtrip');
SQL
compose_at "$SOURCE_PROJECT" exec -T evidence \
  sh -c 'printf "%s\n" "volume-live-roundtrip" > /evidence/roundtrip.txt'

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: real-compose-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: live-compose
    source:
      type: docker_compose
      project_dir: "$SOURCE_PROJECT"
      files: [compose.yaml]
      volumes: [evidence]
      volume_helper_image: "$VOLUME_HELPER_IMAGE"
      command_timeout_seconds: 120
      databases:
        - name: postgres
          service: postgres
          engine: postgres
          user: backfort
          password_env: BACKFORT_REAL_POSTGRES_PASSWORD
          databases: [crm]
          format: custom
        - name: mysql
          service: mysql
          engine: mysql
          user: backfort
          password_env: BACKFORT_REAL_MYSQL_PASSWORD
          databases: [crm]
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 2, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job live-compose --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore-compose latest --job live-compose --to "$STAGING_DIRECTORY" \
  --project-dir "$TARGET_PROJECT" --apply --confirm

[[ "$(compose_at "$TARGET_PROJECT" exec -T postgres \
  psql -At --username backfort --dbname crm -c 'SELECT marker FROM recovery_probe WHERE id = 1')" \
  == postgres-live-roundtrip ]]
[[ "$(compose_at "$TARGET_PROJECT" exec -T -e "MYSQL_PWD=$MYSQL_PASSWORD" mysql \
  mysql --protocol=TCP --host=127.0.0.1 --batch --skip-column-names --user=backfort crm \
  -e 'SELECT marker FROM recovery_probe WHERE id = 1')" == mysql-live-roundtrip ]]
tar --extract --to-stdout --file "$STAGING_DIRECTORY/volumes/evidence/data.tar" ./roundtrip.txt \
  | grep -qx 'volume-live-roundtrip'

printf 'Backfort real Compose database recovery test passed.\n'
