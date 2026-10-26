#!/usr/bin/env bash
# Execute all shell regression drivers on a test layer of the candidate image.
set -Eeuo pipefail
IFS=$'\n\t'
IMAGE=${1:?candidate image is required}
[[ $EUID == 0 ]] || { printf 'The fidelity suite requires root in this disposable runner\n' >&2; exit 2; }
chmod 1777 /tmp
export TMPDIR=/tmp
SOURCE=$(mktemp -d /tmp/backfort-security-source.XXXXXXXX)
chmod 0755 "$SOURCE"
cp /workspace/backfort.sh /workspace/config.example.yaml "$SOURCE/"
cp -r /workspace/tests "$SOURCE/tests"
# Match the repository's LF checkout contract without rewriting Windows files.
find "$SOURCE" -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
chmod 0755 "$SOURCE/backfort.sh" "$SOURCE/tests/"*.sh
find "$SOURCE/tests" -type d -exec chmod 0755 {} +
cmp "$SOURCE/backfort.sh" /usr/local/bin/backfort
cd "$SOURCE"
mkdir -p /reports/tests
bash -n backfort.sh tests/*.sh tests/container/*.sh
shellcheck backfort.sh tests/*.sh tests/container/*.sh
printf 'test\tresult\texit_code\n' >/reports/shell-suite.tsv
failed=0
for test in tests/*.sh; do
  case "$test" in tests/fake-*.sh) continue ;; esac
  name=${test##*/}
  printf 'Running %s\n' "$name"
  command=(bash "$test")
  case "$name" in
    docker-image.sh) command+=("$IMAGE") ;;
    unreadable-file.sh) command=(runuser -u nobody -- bash "$test") ;;
  esac
  if timeout 900 "${command[@]}" >"/reports/tests/$name.log" 2>&1; then
    printf '%s\tPASS\t0\n' "$name" >>/reports/shell-suite.tsv
    printf 'PASS %s\n' "$name"
  else
    result=$?
    printf '%s\tFAIL\t%s\n' "$name" "$result" >>/reports/shell-suite.tsv
    tail -n 25 "/reports/tests/$name.log" >&2
    failed=1
  fi
done
exit "$failed"
