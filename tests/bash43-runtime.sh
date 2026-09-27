#!/usr/bin/env bash

# Regression test for Bash 4.3's `set -u` behaviour: expanding an empty array
# as "${array[@]}" exits non-zero there, unlike modern Bash.
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d)

cleanup() {
  case "$TEST_DIRECTORY" in
    /tmp/*|/var/tmp/*) rm -rf -- "$TEST_DIRECTORY" ;;
  esac
}

# Source the implementation without dispatching its CLI entry point, then use
# actual public helper paths which exercise empty hook and quick-option arrays.
# shellcheck source=/dev/null
source <(sed '/^main "\$@"$/d' "$PROJECT_DIRECTORY/backfort.sh")
trap cleanup EXIT

HOOK_SCRIPT="$TEST_DIRECTORY/hook.sh"
HOOK_OUTPUT="$TEST_DIRECTORY/hook-output"
cat >"$HOOK_SCRIPT" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$BACKFORT_HOOK_PHASE" >"${0%/*}/hook-output"
EOF
chmod 0700 "$HOOK_SCRIPT"

CONFIG_FILE="$TEST_DIRECTORY/config.yaml"

cfg() {
  case "$1" in
    '.jobs[0].hooks.pre.path') printf '%s\n' "$HOOK_SCRIPT" ;;
    '(.jobs[0].hooks.pre.args // []) | length') printf '0\n' ;;
    '.jobs[0].hooks.pre.timeout_seconds // 300') printf '300\n' ;;
    '.jobs[0].source.type') printf 'files\n' ;;
    *)
      printf 'unexpected test configuration lookup: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

job_hook_configured() {
  [[ $1 == 0 && $2 == pre ]]
}

run_job_hook 0 bash43-runtime backup-id pre success 0
[[ $(<"$HOOK_OUTPUT") == pre ]]

mkdir -p "$TEST_DIRECTORY/source" "$TEST_DIRECTORY/backups" "$TEST_DIRECTORY/state"
# These variables are consumed by quick_write_config from the sourced CLI;
# ShellCheck cannot resolve that dynamic call graph in this focused regression.
# shellcheck disable=SC2034
QUICK_NAME=bash43-runtime
# shellcheck disable=SC2034
QUICK_PATHS=("$TEST_DIRECTORY/source")
# shellcheck disable=SC2034
QUICK_DESTINATIONS=("$TEST_DIRECTORY/backups")
# shellcheck disable=SC2034
QUICK_EXCLUDES=()
# shellcheck disable=SC2034
QUICK_STATE_DIRECTORY="$TEST_DIRECTORY/state"
# shellcheck disable=SC2034
QUICK_MIN_COPIES=1
export BACKFORT_QUICK_HOST_ID=bash43-host
quick_write_config
[[ -f $CONFIG_FILE ]]
grep -q 'exclude: \[\]' "$CONFIG_FILE"
grep -q "host_id: 'quick-bash43-host-bash43-runtime'" "$CONFIG_FILE"
unset BACKFORT_QUICK_HOST_ID

# shellcheck disable=SC2034
COMMAND=quick
# shellcheck disable=SC2034
REMAINING_ARGUMENTS=()
parse_command_options

printf 'Backfort Bash 4.3 runtime regression test passed.\n'
