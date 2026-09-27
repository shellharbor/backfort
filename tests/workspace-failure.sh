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

# shellcheck source=/dev/null
source <(sed '/^main "\$@"$/d' "$PROJECT_DIRECTORY/backfort.sh")
trap cleanup EXIT

TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
mkdir -p "$TEMP_DIRECTORY/backfort.stale"
WORK_DIRECTORY="$TEMP_DIRECTORY/backfort.stale"

# Simulate a race or filesystem failure after preflight has accepted the temp
# directory. This must not leave an empty WORK_DIRECTORY for later paths.
mktemp() {
  return 1
}

if make_work_directory; then
  printf 'expected temporary workspace creation to fail\n' >&2
  exit 1
fi
[[ -z $WORK_DIRECTORY ]]

# Consumed by run_job_backup from the sourced CLI implementation.
# shellcheck disable=SC2034
HOST_ID=workspace-host
# shellcheck disable=SC2034
DRY_RUN=false
cfg() {
  case "$1" in
    '.jobs[0].name') printf 'workspace\n' ;;
    '.jobs[0].source.type') printf 'files\n' ;;
    '.jobs[0].compression.method // "gzip"') printf 'none\n' ;;
    '.jobs[0].compression.level // 6') printf '6\n' ;;
    '.jobs[0].encryption.method // "none"') printf 'none\n' ;;
    '.jobs[0].signing.method // "none"') printf 'none\n' ;;
    '.jobs[0].success.min_copies // 1') printf '1\n' ;;
    *)
      printf 'unexpected test configuration lookup: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

if run_job_backup 0 workspace-host_workspace_20250101T000000Z_00000001; then
  printf 'expected backup to stop when workspace creation fails\n' >&2
  exit 1
else
  RESULT=$?
fi
[[ $RESULT -eq 3 ]]
[[ -z $WORK_DIRECTORY ]]
[[ $BACKFORT_EVENT_STAGE == prepare ]]
[[ $BACKFORT_EVENT_ERROR == 'temporary work directory could not be created' ]]

printf 'Backfort workspace failure test passed.\n'
