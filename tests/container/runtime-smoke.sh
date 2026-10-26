#!/usr/bin/env bash
# Run inside the actual production image, without development packages.
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# shellcheck source=/dev/null
. /etc/os-release
[[ $VERSION_CODENAME == trixie ]]
[[ $(readlink -f /usr/bin/awk) == /usr/bin/mawk ]]
[[ $(dpkg-query -W -f='${db:Status-Status}' gawk 2>/dev/null || true) != installed ]]
if command -v gawk >/dev/null 2>&1; then
  printf 'GNU awk must not be installed in the production image\n' >&2
  exit 1
fi

TEST_DIRECTORY=$(mktemp -d /tmp/backfort-runtime-smoke.XXXXXXXX)
cleanup() {
  gpgconf --homedir "$TEST_DIRECTORY/gnupg" --kill gpg-agent >/dev/null 2>&1 || true
  case "$TEST_DIRECTORY" in
    /tmp/backfort-runtime-smoke.*) rm -rf -- "$TEST_DIRECTORY" ;;
    *) printf 'Unexpected runtime test directory: %s\n' "$TEST_DIRECTORY" >&2 ;;
  esac
}
trap cleanup EXIT

printf 'Backfort real crypto round trip\n' >"$TEST_DIRECTORY/plain.txt"
age-keygen -o "$TEST_DIRECTORY/age.key" 2>"$TEST_DIRECTORY/age-keygen.log"
RECIPIENT=$(age-keygen -y "$TEST_DIRECTORY/age.key")
age -r "$RECIPIENT" -o "$TEST_DIRECTORY/plain.age" "$TEST_DIRECTORY/plain.txt"
age -d -i "$TEST_DIRECTORY/age.key" -o "$TEST_DIRECTORY/age-restored.txt" "$TEST_DIRECTORY/plain.age"
cmp "$TEST_DIRECTORY/plain.txt" "$TEST_DIRECTORY/age-restored.txt"

mkdir -m 0700 "$TEST_DIRECTORY/gnupg"
printf '%s' 'synthetic-runtime-test-passphrase' | gpg --homedir "$TEST_DIRECTORY/gnupg" \
  --batch --yes --pinentry-mode loopback --passphrase-fd 0 --symmetric \
  --cipher-algo AES256 --output "$TEST_DIRECTORY/plain.gpg" "$TEST_DIRECTORY/plain.txt"
printf '%s' 'synthetic-runtime-test-passphrase' | gpg --homedir "$TEST_DIRECTORY/gnupg" \
  --batch --yes --pinentry-mode loopback --passphrase-fd 0 --decrypt \
  --output "$TEST_DIRECTORY/gpg-restored.txt" "$TEST_DIRECTORY/plain.gpg"
cmp "$TEST_DIRECTORY/plain.txt" "$TEST_DIRECTORY/gpg-restored.txt"

zstd --quiet -c "$TEST_DIRECTORY/plain.txt" >"$TEST_DIRECTORY/plain.zst"
zstd --quiet -d -c "$TEST_DIRECTORY/plain.zst" >"$TEST_DIRECTORY/zstd-restored.txt"
cmp "$TEST_DIRECTORY/plain.txt" "$TEST_DIRECTORY/zstd-restored.txt"
curl --fail --silent --show-error "file://$TEST_DIRECTORY/plain.txt" >"$TEST_DIRECTORY/curl-restored.txt"
cmp "$TEST_DIRECTORY/plain.txt" "$TEST_DIRECTORY/curl-restored.txt"
# Parse the sendmail-compatible transport configuration without sending mail.
msmtp --pretend --host=smtp.example.test --from=backup@example.test receiver@example.test >/dev/null
[[ $(readlink -f /usr/sbin/sendmail) == /usr/bin/msmtp ]]
flock --nonblock "$TEST_DIRECTORY/probe.lock" true

minisign -G -W -p "$TEST_DIRECTORY/minisign.pub" -s "$TEST_DIRECTORY/minisign.key"
minisign -S -s "$TEST_DIRECTORY/minisign.key" -m "$TEST_DIRECTORY/plain.txt" -x "$TEST_DIRECTORY/plain.minisig"
minisign -V -p "$TEST_DIRECTORY/minisign.pub" -m "$TEST_DIRECTORY/plain.txt" -x "$TEST_DIRECTORY/plain.minisig"

[[ $(printf 'header\n/dev/test 100 30 70 30%% /\n' | awk 'NR == 2 {print $4}') == 70 ]]
[[ $(printf 'abcdef  payload\n' | awk '{print $1}') == abcdef ]]
[[ $(printf 'fpr:::::::::abc123:\n' | awk -F: '$1 == "fpr" {print toupper($10)}') == ABC123 ]]
[[ $(awk 'BEGIN {n=split("a:b", values, ":"); printf "%d:%s", n, values[2]}') == 2:b ]]
# Consume version output fully: head can give the producer SIGPIPE under QEMU.
tar --version | sed -n '1p'
bash --version | sed -n '1p'
mawk -W version 2>&1 | sed -n '1p'
msmtp --version | sed -n '1p'
curl --version | sed -n '1p'
zstd --version
flock --version
age --version
minisign -v
rclone version
docker --version
docker compose version
printf 'Production trixie/mawk and real age/GPG/Minisign runtime smoke passed.\n'
