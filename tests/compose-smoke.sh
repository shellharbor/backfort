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

COMPOSE_DIRECTORY="$TEST_DIRECTORY/compose"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
RESTORE_DIRECTORY="$TEST_DIRECTORY/restore"
FAKE_DOCKER_ROOT="$TEST_DIRECTORY/fake-docker"
REMOTE_DIRECTORY="$TEST_DIRECTORY/remotes"
BIN_DIRECTORY="$TEST_DIRECTORY/bin"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"

mkdir -p "$COMPOSE_DIRECTORY/uploads" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY" \
  "$FAKE_DOCKER_ROOT/volumes/fake_media" "$REMOTE_DIRECTORY" "$BIN_DIRECTORY"
printf 'application upload\n' >"$COMPOSE_DIRECTORY/uploads/asset.txt"
printf 'volume content\n' >"$FAKE_DOCKER_ROOT/volumes/fake_media/volume.txt"
cat >"$COMPOSE_DIRECTORY/compose.yaml" <<'EOF'
services:
  app: {image: example/app:latest}
  postgres: {image: postgres:17}
  mysql: {image: mysql:8}
  mariadb: {image: mariadb:11}
  mssql: {image: mcr.microsoft.com/mssql/server:2022-latest}
  oracle: {image: gvenzl/oracle-free:latest}
volumes:
  media: {}
EOF
ln -s "$PROJECT_DIRECTORY/tests/fake-docker.sh" "$BIN_DIRECTORY/docker"
ln -s "$PROJECT_DIRECTORY/tests/fake-rclone.sh" "$BIN_DIRECTORY/rclone"

export BACKFORT_FAKE_DOCKER_ROOT="$FAKE_DOCKER_ROOT"
export BACKFORT_FAKE_DOCKER_LOG="$TEST_DIRECTORY/docker.log"
export BACKFORT_FAKE_RCLONE_ROOT="$REMOTE_DIRECTORY"
export XDG_STATE_HOME="$TEST_DIRECTORY/quick-state"
export BACKFORT_TEST_PG_PASSWORD='test-pg-secret'
export BACKFORT_TEST_MYSQL_PASSWORD='test-mysql-secret'
export BACKFORT_TEST_MARIADB_PASSWORD='test-mariadb-secret'
export BACKFORT_TEST_MSSQL_PASSWORD='test-mssql-secret'
export BACKFORT_TEST_ORACLE_PASSWORD='test-oracle-secret'
export PATH="$BIN_DIRECTORY:$PATH"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: compose-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: crm
    source:
      type: docker_compose
      project_dir: "$COMPOSE_DIRECTORY"
      files: [compose.yaml]
      volumes: [media]
      volume_helper_image: example/backfort-volume-helper:1
      bind_mounts:
        - name: uploads
          path: uploads
      databases:
        - name: postgres
          service: postgres
          engine: postgres
          user: backfort
          password_env: BACKFORT_TEST_PG_PASSWORD
          databases: [crm]
          include_globals: true
        - name: mysql
          service: mysql
          engine: mysql
          user: backfort
          password_env: BACKFORT_TEST_MYSQL_PASSWORD
          databases: [crm]
        - name: mariadb
          service: mariadb
          engine: mariadb
          user: backfort
          password_env: BACKFORT_TEST_MARIADB_PASSWORD
          databases: [crm]
        - name: mssql
          service: mssql
          engine: mssql
          user: backfort
          password_env: BACKFORT_TEST_MSSQL_PASSWORD
          databases: [crm]
          backup_directory: /var/opt/mssql/backups
        - name: oracle
          service: oracle
          engine: oracle
          user: backfort
          password_env: BACKFORT_TEST_ORACLE_PASSWORD
          connect: FREEPDB1
          directory: DATA_PUMP_DIR
          path: /opt/oracle/admin/FREE/dpdump
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 2, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" --dry-run run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" verify latest --job crm --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" restore latest --job crm --to "$RESTORE_DIRECTORY"

[[ -f "$RESTORE_DIRECTORY/compose/compose.yaml" ]]
diff "$COMPOSE_DIRECTORY/uploads/asset.txt" "$RESTORE_DIRECTORY/bind-mounts/uploads/asset.txt"
tar --extract --to-stdout --file "$RESTORE_DIRECTORY/volumes/media/data.tar" ./volume.txt | grep -q 'volume content'
grep -q 'volume-snapshot fake_media capability=DAC_READ_SEARCH' "$BACKFORT_FAKE_DOCKER_LOG"
grep -q 'postgres custom dump' "$RESTORE_DIRECTORY/databases/postgres/crm.dump"
grep -q 'postgres globals' "$RESTORE_DIRECTORY/databases/postgres/globals.sql"
grep -q 'mysql logical dump' "$RESTORE_DIRECTORY/databases/mysql/crm.sql"
grep -q 'mysql logical dump' "$RESTORE_DIRECTORY/databases/mariadb/crm.sql"
grep -q 'mssql native backup' "$RESTORE_DIRECTORY/databases/mssql/crm.bak"
grep -q 'oracle data pump export' "$RESTORE_DIRECTORY/databases/oracle/full.dmp"
if grep -q 'test-.*-secret' "$BACKFORT_FAKE_DOCKER_LOG"; then
  printf 'test secret leaked into the fake Docker log\n' >&2
  exit 1
fi
if find "$FAKE_DOCKER_ROOT/containers/fake-mssql/var/opt/mssql/backups" \
  -type f -name 'backfort_*.bak' -print -quit | grep -q .; then
  printf 'temporary MS SQL backup file was not cleaned up\n' >&2
  exit 1
fi
if find "$FAKE_DOCKER_ROOT/containers/fake-oracle/opt/oracle/admin/FREE/dpdump" \
  -type f \( -name 'backfort_*.dmp' -o -name 'backfort_*.log' \) -print -quit | grep -q .; then
  printf 'temporary Oracle export files were not cleaned up\n' >&2
  exit 1
fi

QUICK_BACKUP_DIRECTORY="$TEST_DIRECTORY/quick-backups"
QUICK_RESTORE_DIRECTORY="$TEST_DIRECTORY/quick-restore"
QUICK_MANAGED_RESTORE_DIRECTORY="$TEST_DIRECTORY/quick-managed-restore"
"$PROJECT_DIRECTORY/backfort.sh" quick-compose "$COMPOSE_DIRECTORY" \
  --name quick-crm \
  --to "$QUICK_BACKUP_DIRECTORY" \
  --to rclone:fake:quick/crm \
  --min-copies 2 \
  --volume media \
  --volume-helper-image example/backfort-volume-helper:1 \
  --bind uploads:uploads \
  --db postgres:postgres:postgres:backfort:BACKFORT_TEST_PG_PASSWORD:crm \
  --db mysql:mysql:mysql:backfort:BACKFORT_TEST_MYSQL_PASSWORD:crm

QUICK_PAYLOAD=$(find "$QUICK_BACKUP_DIRECTORY" -name '*.tar.gz' -type f -print -quit)
[[ -n $QUICK_PAYLOAD ]]
QUICK_REMOTE_PAYLOAD=$(find "$REMOTE_DIRECTORY/quick/crm" -name '*.tar.gz' -type f -print -quit)
[[ -n $QUICK_REMOTE_PAYLOAD ]]
QUICK_CONFIG_FILE="$XDG_STATE_HOME/backfort/quick-compose/quick-crm.yaml"
[[ -f $QUICK_CONFIG_FILE ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$QUICK_CONFIG_FILE" verify latest --job quick-crm --full
"$PROJECT_DIRECTORY/backfort.sh" -c "$QUICK_CONFIG_FILE" \
  restore latest --job quick-crm --to "$QUICK_MANAGED_RESTORE_DIRECTORY"
grep -q 'postgres plain SQL dump' "$QUICK_MANAGED_RESTORE_DIRECTORY/databases/postgres/crm.sql"
mkdir -p "$QUICK_RESTORE_DIRECTORY"
tar --extract --gzip --file "$QUICK_PAYLOAD" --directory "$QUICK_RESTORE_DIRECTORY"
[[ -f "$QUICK_RESTORE_DIRECTORY/data/compose/compose.yaml" ]]
diff "$COMPOSE_DIRECTORY/uploads/asset.txt" "$QUICK_RESTORE_DIRECTORY/data/bind-mounts/uploads/asset.txt"
tar --extract --to-stdout --file "$QUICK_RESTORE_DIRECTORY/data/volumes/media/data.tar" ./volume.txt | grep -q 'volume content'
grep -q 'postgres plain SQL dump' "$QUICK_RESTORE_DIRECTORY/data/databases/postgres/crm.sql"
grep -q 'mysql logical dump' "$QUICK_RESTORE_DIRECTORY/data/databases/mysql/crm.sql"

printf 'Backfort Compose smoke test passed.\n'
