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
TARGET_DIRECTORY="$TEST_DIRECTORY/target"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
FAKE_DOCKER_ROOT="$TEST_DIRECTORY/fake-docker"
BIN_DIRECTORY="$TEST_DIRECTORY/bin"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
STAGED_DIRECTORY="$TEST_DIRECTORY/staged"
APPLY_DIRECTORY="$TEST_DIRECTORY/apply-staged"
DRY_RUN_DIRECTORY="$TEST_DIRECTORY/dry-run-staged"

mkdir -p "$SOURCE_DIRECTORY" "$TARGET_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" \
  "$TEMP_DIRECTORY" "$FAKE_DOCKER_ROOT" "$BIN_DIRECTORY"
cat >"$SOURCE_DIRECTORY/compose.yaml" <<'EOF'
services:
  postgres: {image: postgres:17}
  mysql: {image: mysql:8}
  mariadb: {image: mariadb:11}
EOF
cp -- "$SOURCE_DIRECTORY/compose.yaml" "$TARGET_DIRECTORY/compose.yaml"
ln -s "$PROJECT_DIRECTORY/tests/fake-docker.sh" "$BIN_DIRECTORY/docker"

export BACKFORT_FAKE_DOCKER_ROOT="$FAKE_DOCKER_ROOT"
export BACKFORT_FAKE_DOCKER_LOG="$TEST_DIRECTORY/docker.log"
export BACKFORT_TEST_PG_PASSWORD='restore-pg-secret'
export BACKFORT_TEST_MYSQL_PASSWORD='restore-mysql-secret'
export BACKFORT_TEST_MARIADB_PASSWORD='restore-mariadb-secret'
export PATH="$BIN_DIRECTORY:$PATH"

cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: restore-compose-host
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
      project_dir: "$SOURCE_DIRECTORY"
      files: [compose.yaml]
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
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: gzip, level: 6}
    encryption: {method: none}
    retention: {keep_last: 2, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore-compose latest --job crm --to "$STAGED_DIRECTORY" >"$TEST_DIRECTORY/staged-plan.txt"

[[ -f "$STAGED_DIRECTORY/compose/compose.yaml" ]]
grep -Fq "compose_database name=postgres engine=postgres format=custom directory=$STAGED_DIRECTORY/databases/postgres action=apply-available" "$TEST_DIRECTORY/staged-plan.txt"
grep -Fq 'compose_database_globals name=postgres' "$TEST_DIRECTORY/staged-plan.txt"
grep -Fq 'action=manual-review-required' "$TEST_DIRECTORY/staged-plan.txt"
if grep -Fq 'compose-restore ' "$BACKFORT_FAKE_DOCKER_LOG"; then
  printf 'staging unexpectedly imported a database\n' >&2
  exit 1
fi

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" --dry-run \
  restore-compose latest --job crm --to "$DRY_RUN_DIRECTORY" >"$TEST_DIRECTORY/dry-run-plan.txt"
[[ ! -e $DRY_RUN_DIRECTORY ]]
grep -Fq 'next=review-staged-data-and-prepare-an-isolated-target-project' "$TEST_DIRECTORY/dry-run-plan.txt"

set +e
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore-compose latest --job crm --to "$TEST_DIRECTORY/no-confirm" --project-dir "$TARGET_DIRECTORY" --apply \
  >"$TEST_DIRECTORY/no-confirm.out" 2>&1
NO_CONFIRM_STATUS=$?
set -e
[[ $NO_CONFIRM_STATUS -eq 2 ]]
grep -Fq 'restore-compose-apply-requires-confirm' "$TEST_DIRECTORY/no-confirm.out"
[[ ! -e "$TEST_DIRECTORY/no-confirm" ]]

"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" \
  restore-compose latest --job crm --to "$APPLY_DIRECTORY" \
  --project-dir "$TARGET_DIRECTORY" --apply --confirm >"$TEST_DIRECTORY/apply-plan.txt"

[[ -f "$APPLY_DIRECTORY/databases/postgres/crm.dump" ]]
grep -Fq 'compose-restore postgres pg_restore' "$BACKFORT_FAKE_DOCKER_LOG"
grep -Fq 'compose-restore mysql mysql' "$BACKFORT_FAKE_DOCKER_LOG"
grep -Fq 'compose-restore mariadb mariadb' "$BACKFORT_FAKE_DOCKER_LOG"
if grep -Eq 'restore-(pg|mysql|mariadb)-secret' "$BACKFORT_FAKE_DOCKER_LOG"; then
  printf 'restore secret leaked into the fake Docker log\n' >&2
  exit 1
fi

printf 'Backfort Compose restore assistant test passed.\n'
