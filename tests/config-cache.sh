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

# Source the public helper without dispatching the CLI. The fake yq records
# process launches, so this test proves both successful caching and that an
# error is never cached as a successful value.
# shellcheck source=/dev/null
source <(sed '/^main "\$@"$/d' "$PROJECT_DIRECTORY/backfort.sh")
trap cleanup EXIT

COUNTER_FILE="$TEST_DIRECTORY/yq-calls"
CONFIG_CACHE_FILE="$TEST_DIRECTORY/config-cache"
: >"$CONFIG_CACHE_FILE"
CONFIG_FILE="$TEST_DIRECTORY/one.yaml"
printf 'version: 1\n' >"$CONFIG_FILE"

cache_path=$(bash -c '
  # shellcheck disable=SC1090
  source <(sed '\''/^main "\$@"$/d'\'' "$1")
  TMPDIR=$2
  make_config_cache_file
  printf "%s" "$CONFIG_CACHE_FILE"
' bash "$PROJECT_DIRECTORY/backfort.sh" "$TEST_DIRECTORY")
[[ -n $cache_path && ! -e $cache_path ]]

yq() {
  printf '%s\n' "$3" >>"$COUNTER_FILE"
  [[ $3 != '.failure' ]] || return 1
  [[ $3 != '.empty' ]] || return 0
  printf 'value:%s\n' "$3"
}

[[ $(cfg '.jobs[0].name') == 'value:.jobs[0].name' ]]
[[ $(cfg '.jobs[0].name') == 'value:.jobs[0].name' ]]
[[ $(wc -l <"$COUNTER_FILE") -eq 1 ]]

CONFIG_FILE="$TEST_DIRECTORY/two.yaml"
printf 'version: 1\n' >"$CONFIG_FILE"
[[ $(cfg '.jobs[0].name') == 'value:.jobs[0].name' ]]
[[ $(wc -l <"$COUNTER_FILE") -eq 2 ]]

empty_lines=()
mapfile -t empty_lines < <(cfg '.empty')
[[ ${#empty_lines[@]} -eq 0 ]]
mapfile -t empty_lines < <(cfg '.empty')
[[ ${#empty_lines[@]} -eq 0 ]]
[[ $(wc -l <"$COUNTER_FILE") -eq 3 ]]

if cfg '.failure' >/dev/null 2>&1; then
  printf 'expected fake yq failure\n' >&2
  exit 1
fi
if cfg '.failure' >/dev/null 2>&1; then
  printf 'expected uncached fake yq failure\n' >&2
  exit 1
fi
[[ $(wc -l <"$COUNTER_FILE") -eq 5 ]]

printf 'Backfort config cache test passed.\n'
