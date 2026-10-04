#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

IMAGE=${1:?usage: tests/docker-image.sh IMAGE}
PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EXPECTED_VERSION=$(sed -n 's/^readonly BACKFORT_VERSION="\([^"]*\)"$/\1/p' "$PROJECT_DIRECTORY/backfort.sh")
TEST_DIRECTORY=$(mktemp -d /tmp/backfort-docker-image.XXXXXXXX)
STATE_VOLUME="backfort-docker-state-${RANDOM}-$$"
TEMP_VOLUME="backfort-docker-temp-${RANDOM}-$$"

cleanup() {
  local result=$?

  trap - EXIT
  set +e
  docker volume rm -f "$STATE_VOLUME" "$TEMP_VOLUME" >/dev/null 2>&1
  case "$TEST_DIRECTORY" in
    /tmp/backfort-docker-image.*) rm -rf -- "$TEST_DIRECTORY" ;;
    *) printf 'refusing to remove unexpected test directory: %s\n' "$TEST_DIRECTORY" >&2 ;;
  esac
  exit "$result"
}
trap cleanup EXIT

SOURCE_DIRECTORY="$TEST_DIRECTORY/source"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
RESTORE_DIRECTORY="$TEST_DIRECTORY/restore"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
INVALID_CONFIG_FILE="$TEST_DIRECTORY/invalid.yaml"

mkdir -p -- "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY"
printf 'container round-trip\n' >"$SOURCE_DIRECTORY/probe.txt"
chmod 0755 "$TEST_DIRECTORY" "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY"

cat >"$CONFIG_FILE" <<'EOF'
version: 1
settings:
  host_id: docker-image-host
  state_directory: /var/lib/backfort
  temp_directory: /var/tmp/backfort
  lock_file: /var/lib/backfort/backfort.lock
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: /backups
jobs:
  - name: container-files
    source:
      type: files
      paths: [/source]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: none}
    encryption: {method: none}
    signing: {method: none}
    retention: {keep_last: 2, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
EOF
cat >"$INVALID_CONFIG_FILE" <<'EOF'
version: 1
unexpected: true
EOF

run_image() {
  docker run --rm --read-only --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m \
    -v "$STATE_VOLUME:/var/lib/backfort" \
    -v "$TEMP_VOLUME:/var/tmp/backfort" \
    -v "$SOURCE_DIRECTORY:/source:ro" \
    -v "$BACKUP_DIRECTORY:/backups" \
    -v "$RESTORE_DIRECTORY:/restore" \
    -v "$CONFIG_FILE:/etc/backfort/config.yaml:ro" \
    "$IMAGE" "$@"
}

[[ "$(docker run --rm "$IMAGE" --version)" == "Backfort $EXPECTED_VERSION" ]]
docker run --rm --read-only --entrypoint /bin/sh "$IMAGE" -ec '
  yq --version >/dev/null
  rclone version >/dev/null
  docker compose version >/dev/null
'
run_image doctor
run_image run
run_image verify latest --job container-files --full
run_image list --job container-files | grep -q 'docker-image-host_container-files_'
run_image restore latest --job container-files --to /restore

docker run --rm --read-only -v "$RESTORE_DIRECTORY:/restore:ro" \
  --entrypoint /bin/sh "$IMAGE" -ec 'grep -qx "container round-trip" /restore/source/probe.txt'

if docker run --rm --read-only --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m \
  -v "$INVALID_CONFIG_FILE:/etc/backfort/config.yaml:ro" \
  "$IMAGE" doctor >"$TEST_DIRECTORY/invalid.out" 2>&1; then
  printf 'invalid container configuration unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'kind=config' "$TEST_DIRECTORY/invalid.out"

printf 'Backfort Docker image test passed.\n'
