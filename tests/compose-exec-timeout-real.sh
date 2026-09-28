#!/usr/bin/env bash

# Exercises compose_exec_with_secret against a real Docker Compose service.
# Killing the docker CLI client (whether by a host-side timeout or any other
# means) does not stop a process it started inside the container's own PID
# namespace: only an in-container timeout, wrapping the actual command, does
# that. This test proves the process is genuinely gone from inside the
# container, not just detached from the client that started it.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d /tmp/backfort-compose-exec-timeout.XXXXXXXX)

# No explicit -p: docker_compose_job_with_timeout (the function under test)
# never passes one either, so this must derive the same implicit project
# name from --project-directory that it will.
compose() {
  docker compose --project-directory "$TEST_DIRECTORY" -f "$TEST_DIRECTORY/compose.yaml" "$@"
}

cleanup() {
  local result=$?
  trap - EXIT
  set +e
  compose down --timeout 0 >/dev/null 2>&1
  case "$TEST_DIRECTORY" in
    /tmp/backfort-compose-exec-timeout.*) rm -rf -- "$TEST_DIRECTORY" ;;
    *) printf 'refusing to remove unexpected test directory: %s\n' "$TEST_DIRECTORY" >&2 ;;
  esac
  exit "$result"
}
trap cleanup EXIT

cat >"$TEST_DIRECTORY/compose.yaml" <<'EOF'
services:
  probe:
    image: alpine:latest
    command: ["sleep", "infinity"]
EOF

compose up --detach probe

# shellcheck source=/dev/null
source <(sed '/^main "\$@"$/d' "$PROJECT_DIRECTORY/backfort.sh")

# A minimal stand-in for a real YAML config: only the fields
# compose_exec_with_secret and its callees actually read.
cfg() {
  case "$1" in
    '.jobs[0].name') printf 'probe-job\n' ;;
    '.jobs[0].source.project_dir') printf '%s\n' "$TEST_DIRECTORY" ;;
    '.jobs[0].source.files | length') printf '1\n' ;;
    '.jobs[0].source.files[0]') printf 'compose.yaml\n' ;;
    '.jobs[0].source.command_timeout_seconds // 3600') printf '2\n' ;;
    '.jobs[0].source.databases[0].password_env') printf 'BACKFORT_TEST_EXEC_TIMEOUT_PW\n' ;;
    *) return 1 ;;
  esac
}

export BACKFORT_TEST_EXEC_TIMEOUT_PW=irrelevant

# A fast command must still succeed well within the timeout: the wrap must
# not itself break or meaningfully delay a normal dump.
if ! compose_exec_with_secret 0 0 TESTVAR probe echo ok >"$TEST_DIRECTORY/fast.out"; then
  printf 'a fast in-container command must succeed under the timeout wrap\n' >&2
  exit 1
fi
[[ $(<"$TEST_DIRECTORY/fast.out") == ok ]]

# A command that ignores its terminal is bounded by the in-container timeout
# (2s) plus its 10s kill grace, not by the sleep duration (600s).
STARTED=$(date -u +%s)
if compose_exec_with_secret 0 0 TESTVAR probe sh -c 'trap "" TERM; sleep 600'; then
  printf 'expected the long-running in-container command to be killed\n' >&2
  exit 1
fi
ELAPSED=$(( $(date -u +%s) - STARTED ))
((ELAPSED < 60)) || {
  printf 'compose_exec_with_secret took %ss; the in-container timeout did not bound it\n' "$ELAPSED" >&2
  exit 1
}

# The proof that matters: the process is actually gone from inside the
# container's own PID namespace, not merely detached from a killed client.
# The in-container timeout runs on its own clock, independent of how fast
# the host-side docker CLI client died, and its own 10s kill grace (the
# process ignores SIGTERM) has not necessarily elapsed yet the moment
# compose_exec_with_secret returns, so poll instead of a single fixed wait.
GONE=false
for _ in $(seq 1 20); do
  if ! compose exec -T probe sh -c "pgrep -f 'sleep 600' >/dev/null"; then
    GONE=true
    break
  fi
  sleep 1
done
if [[ $GONE == false ]]; then
  printf 'the long-running process is still running inside the container\n' >&2
  compose exec -T probe ps -o pid,args >&2 || true
  exit 1
fi

printf 'Backfort in-container exec timeout test passed.\n'
