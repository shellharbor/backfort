#!/usr/bin/env bash
# Docker Desktop: expose the test runner's /tmp named volume to sibling binds.
# This changes only CLI bind paths, never Compose services or production data.
set -Eeuo pipefail
IFS=$'\n\t'
[[ ${BACKFORT_TEST_HOST_TMP:-} == /var/lib/docker/volumes/backfort-security-*/_data ]] \
  || { printf 'Missing validated Backfort test-volume path\n' >&2; exit 2; }
arguments=()
while (($#)); do
  case "$1" in
    -v|--volume)
      (($# >= 2)) || exit 2
      volume=$2
      [[ $volume != /tmp/* ]] || volume="$BACKFORT_TEST_HOST_TMP/${volume#/tmp/}"
      arguments+=("$1" "$volume")
      shift 2
      ;;
    --mount)
      (($# >= 2)) || exit 2
      mount=$2
      mount=${mount//source=\/tmp\//source=$BACKFORT_TEST_HOST_TMP/}
      mount=${mount//src=\/tmp\//src=$BACKFORT_TEST_HOST_TMP/}
      arguments+=("$1" "$mount")
      shift 2
      ;;
    *) arguments+=("$1"); shift ;;
  esac
done
exec /usr/local/bin/docker-real "${arguments[@]}"
