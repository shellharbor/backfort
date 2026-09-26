#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIRECTORY=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIRECTORY=$(mktemp -d)
PORT=18976
SERVER_PID=''

cleanup() {
  if [[ -n $SERVER_PID ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  case "$TEST_DIRECTORY" in
    /tmp/*|/var/tmp/*) rm -rf -- "$TEST_DIRECTORY" ;;
  esac
}
trap cleanup EXIT

SOURCE_DIRECTORY="$TEST_DIRECTORY/source"
BACKUP_DIRECTORY="$TEST_DIRECTORY/backups"
STATE_DIRECTORY="$TEST_DIRECTORY/state"
TEMP_DIRECTORY="$TEST_DIRECTORY/temp"
BIN_DIRECTORY="$TEST_DIRECTORY/bin"
REQUEST_DIRECTORY="$TEST_DIRECTORY/requests"
CONFIG_FILE="$TEST_DIRECTORY/config.yaml"
REAL_CURL=$(command -v curl)

mkdir -p "$SOURCE_DIRECTORY" "$BACKUP_DIRECTORY" "$STATE_DIRECTORY" "$TEMP_DIRECTORY" "$BIN_DIRECTORY" "$REQUEST_DIRECTORY"
printf 'notification test content\n' >"$SOURCE_DIRECTORY/data.txt"

cat >"$TEST_DIRECTORY/receiver.py" <<'PY'
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys

directory = Path(sys.argv[2])
counter = 0

class Receiver(BaseHTTPRequestHandler):
    def do_POST(self):
        global counter
        counter += 1
        length = int(self.headers.get("Content-Length", "0"))
        (directory / f"{counter}.body").write_bytes(self.rfile.read(length))
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, format, *args):
        pass

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Receiver).serve_forever()
PY
python3 "$TEST_DIRECTORY/receiver.py" "$PORT" "$REQUEST_DIRECTORY" &
SERVER_PID=$!
sleep 0.2
kill -0 "$SERVER_PID"

# This test-only proxy maps the Telegram endpoint to the local receiver.
cat >"$BIN_DIRECTORY/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

config=''
previous=''
for argument in "$@"; do
  if [[ $previous == --config ]]; then
    config=$argument
    break
  fi
  previous=$argument
done
if [[ -n $config ]] && grep -q 'api.telegram.org' "$config"; then
  sed -i "s#^url = .*#url = \"http://127.0.0.1:$BACKFORT_TEST_NOTIFY_PORT/telegram\"#" "$config"
fi
exec "$BACKFORT_REAL_CURL" "$@"
EOF
chmod 0755 "$BIN_DIRECTORY/curl"

export BACKFORT_TEST_NOTIFY_PORT="$PORT"
export BACKFORT_REAL_CURL="$REAL_CURL"
export PATH="$BIN_DIRECTORY:$PATH"
export BACKFORT_TG_TOKEN='123456:telegram_test_token'
export BACKFORT_TG_CHAT='-100123456'
export BACKFORT_WEBHOOK_URL="http://127.0.0.1:$PORT/webhook"

reset_requests() {
  rm -f -- "$REQUEST_DIRECTORY"/*
}

request_count() {
  find "$REQUEST_DIRECTORY" -maxdepth 1 -name '*.body' | wc -l
}

latest_body() {
  find "$REQUEST_DIRECTORY" -maxdepth 1 -name '*.body' -print | sort -V | tail -n 1
}

telegram_text() {
  yq eval -r '.text' "$(latest_body)"
}

wait_for_requests() {
  local expected=$1
  local count
  for _ in {1..50}; do
    count=$(request_count)
    ((count >= expected)) && return 0
    sleep 0.1
  done
  printf 'expected %s requests, got %s\n' "$expected" "$(request_count)" >&2
  return 1
}

write_config() {
  local notifications=$1
  cat >"$CONFIG_FILE" <<EOF
version: 1
settings:
  host_id: notify-host
  state_directory: "$STATE_DIRECTORY"
  temp_directory: "$TEMP_DIRECTORY"
  lock_file: "$TEST_DIRECTORY/backfort.lock"
  min_free_mb: 1
destinations:
  - name: local
    type: local
    path: "$BACKUP_DIRECTORY"
jobs:
  - name: notify
    source:
      type: files
      paths: ["$SOURCE_DIRECTORY"]
      exclude: []
      follow_symlinks: false
    destinations: [local]
    success: {min_copies: 1}
    compression: {method: none}
    encryption: {method: none}
    retention: {keep_last: 20, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}
$notifications
EOF
}

telegram_events='notifications:
  enabled: true
  defaults: {events: [failure, partial, recovery, watchdog], antiflood_hours: 4}
  channels:
    - name: ops-telegram
      type: telegram
      token_env: BACKFORT_TG_TOKEN
      chat_id_env: BACKFORT_TG_CHAT
      events: [success, failure, recovery, partial]'

# Success is opt-in: this Telegram channel gets it because it selected success.
reset_requests
write_config "$telegram_events"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >"$TEST_DIRECTORY/success.out" 2>"$TEST_DIRECTORY/success.err"
wait_for_requests 1
grep -Fq '[backfort] OK' "$(latest_body)"

# Failure -> recovery is transition-only; a third successful run is silent.
reset_requests
rm -rf -- "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
mkdir -p "$STATE_DIRECTORY" "$BACKUP_DIRECTORY" "$BIN_DIRECTORY/failing"
cat >"$BIN_DIRECTORY/failing/tar" <<'EOF'
#!/usr/bin/env bash
printf 'TOKEN=abcdef1234567890abcdef1234567890 0123456789abcdef0123456789abcdef\n' >&2
exit 1
EOF
chmod 0755 "$BIN_DIRECTORY/failing/tar"
if PATH="$BIN_DIRECTORY/failing:$PATH" "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/failure.err"; then
  exit 1
else
  [[ $? -eq 3 ]]
fi
wait_for_requests 1
grep -Fq '[backfort] FAILURE' "$(latest_body)"
FAILURE_TEXT=$(telegram_text)
grep -Fq 'FAILURE job=notify host=notify-host error=backup packaging failed' <<<"$FAILURE_TEXT"
grep -Fq 'Restore: sudo backfort.sh -c ' <<<"$FAILURE_TEXT"
grep -Fq -- "-c $CONFIG_FILE restore" <<<"$FAILURE_TEXT"
FAILURE_BACKUP_ID=$(sed -n 's/.* restore \([^ ]*\) --to .*/\1/p' <<<"$FAILURE_TEXT")
[[ $FAILURE_BACKUP_ID =~ ^notify-host_notify_[0-9]{8}T[0-9]{6}Z_[A-Fa-f0-9]{8}$ ]]
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/recovery.err"
wait_for_requests 2
grep -Fq '[backfort] RECOVERED' "$(latest_body)"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/steady.err"
sleep 0.2
[[ $(request_count) -eq 2 ]]

# A partial publish provides successful and failed destination names.
reset_requests
printf 'blocked\n' >"$TEST_DIRECTORY/not-a-directory"
write_config "$telegram_events"
BF_BLOCKED_PATH="$TEST_DIRECTORY/not-a-directory/unavailable" \
  yq eval '.destinations += [{"name":"blocked","type":"local","path":strenv(BF_BLOCKED_PATH)}] | .jobs[0].destinations = ["local","blocked"]' -i "$CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/partial.err"; then
  exit 1
else
  [[ $? -eq 1 ]]
fi
wait_for_requests 1
grep -Fq '[backfort] PARTIAL' "$(latest_body)"
grep -Fq 'blocked' "$(latest_body)"

webhook_events='notifications:
  enabled: true
  channels:
    - name: ci-webhook
      type: webhook
      url_env: BACKFORT_WEBHOOK_URL
      headers_env: BACKFORT_WEBHOOK_HEADERS
      events: [success, failure]'

# Webhook bodies are valid yq-created JSON.
reset_requests
rm -rf -- "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
mkdir -p "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
unset BACKFORT_WEBHOOK_HEADERS
write_config "$webhook_events"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/webhook.err"
wait_for_requests 1
yq eval '.event == "success" and .data.job == "notify"' "$(latest_body)" | grep -qx true

# Digest records success activity and flushes it on the next Backfort event.
reset_requests
rm -rf -- "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
mkdir -p "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
digest_events='notifications:
  enabled: true
  defaults: {digest: daily}
  channels:
    - name: ci-webhook
      type: webhook
      url_env: BACKFORT_WEBHOOK_URL
      events: [success]'
write_config "$digest_events"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/digest-record.err"
[[ $(request_count) -eq 0 ]]
mv "$STATE_DIRECTORY/notify_digest/$(date -u +%F).log" "$STATE_DIRECTORY/notify_digest/2000-01-01.log"
cat >"$TEST_DIRECTORY/event-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source <(head -n -1 "$1")
CONFIG_FILE=$2
check_yq
validate_config
initialize_notifications
bf_notify watchdog
EOF
chmod 0700 "$TEST_DIRECTORY/event-helper.sh"
BACKFORT_EVENT_JOB=notify BACKFORT_EVENT_STAGE=watchdog \
  "$TEST_DIRECTORY/event-helper.sh" "$PROJECT_DIRECTORY/backfort.sh" "$CONFIG_FILE"
wait_for_requests 1
grep -Fq 'daily digest' "$(latest_body)"

# A dead channel and a missing secret warn but do not break a completed backup.
reset_requests
rm -rf -- "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
mkdir -p "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
export BACKFORT_WEBHOOK_URL='http://127.0.0.1:1/unreachable'
write_config "$webhook_events"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/unreachable.err"
grep -Fq 'kind=notify' "$TEST_DIRECTORY/unreachable.err"
find "$BACKUP_DIRECTORY" -maxdepth 1 -name '*.complete' -print -quit | grep -q .
export BACKFORT_WEBHOOK_URL="http://127.0.0.1:$PORT/webhook"

rm -rf -- "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
mkdir -p "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
unset BACKFORT_TG_TOKEN
write_config "$telegram_events"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/missing.err"
grep -Fq 'kind=notify' "$TEST_DIRECTORY/missing.err"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" doctor >"$TEST_DIRECTORY/doctor.out" 2>"$TEST_DIRECTORY/doctor.err"
grep -Fq 'channel=ops-telegram type=telegram status=warn reason=missing-env=BACKFORT_TG_TOKEN' "$TEST_DIRECTORY/doctor.out"
export BACKFORT_TG_TOKEN='123456:telegram_test_token'

# Invalid notification schema is rejected before a backup is attempted.
write_config "$webhook_events"
yq eval '.notifications.channels[0].unexpected = true' -i "$CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/unknown.err"; then exit 1; else [[ $? -eq 2 ]]; fi
yq eval '.notifications.channels[0] |= del(.unexpected) | .notifications.channels[0].type = "smoke_signal"' -i "$CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/type.err"; then exit 1; else [[ $? -eq 2 ]]; fi
yq eval '.notifications.channels[0].type = "webhook" | .notifications.channels[0].events = ["outside-enum"]' -i "$CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/event.err"; then exit 1; else [[ $? -eq 2 ]]; fi

# Antiflood suppresses the second failure and allows one after aging state.
reset_requests
rm -rf -- "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
mkdir -p "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
write_config "$telegram_events"
if PATH="$BIN_DIRECTORY/failing:$PATH" "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/anti-one.err"; then exit 1; fi
wait_for_requests 1
if PATH="$BIN_DIRECTORY/failing:$PATH" "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/anti-two.err"; then exit 1; fi
grep -Fq 'notify_suppressed event=failure channel=ops-telegram' "$TEST_DIRECTORY/anti-two.err"
[[ $(request_count) -eq 1 ]]
printf '%s\n' "$(( $(date -u +%s) - 18000 ))" >"$STATE_DIRECTORY/notify_state/notify.ops-telegram.failure.last_sent"
if PATH="$BIN_DIRECTORY/failing:$PATH" "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/anti-three.err"; then exit 1; fi
wait_for_requests 2

# Per-channel templates keep trusted literal Telegram HTML while escaping every
# substituted value. Direct bf_notify use gives this seam a deliberately hostile
# event value without weakening the config's identifier validation.
templated_telegram_events='notifications:
  enabled: true
  channels:
    - name: ops-telegram
      type: telegram
      token_env: BACKFORT_TG_TOKEN
      chat_id_env: BACKFORT_TG_CHAT
      events: [failure]
      templates:
        failure: |-
          <b>Action for {{job}}</b>
          {{error}}
          <code>{{restore_hint}}</code>'
reset_requests
rm -rf -- "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
mkdir -p "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
write_config "$templated_telegram_events"
cat >"$TEST_DIRECTORY/template-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source <(head -n -1 "$1")
CONFIG_FILE=$2
check_yq
validate_config
initialize_notifications
bf_notify failure
EOF
chmod 0700 "$TEST_DIRECTORY/template-helper.sh"
PWN_FILE="/tmp/backfort-notify-template-pwn-$RANDOM"
BACKFORT_EVENT_JOB='notify<script>&' \
  BACKFORT_EVENT_ID='notify-host_notify_20260925T021500Z_a91f3c2d' \
  BACKFORT_EVENT_ERROR="<script>& \$(touch $PWN_FILE) \`ignored\`" \
  BACKFORT_EVENT_EXIT_CODE=3 \
  "$TEST_DIRECTORY/template-helper.sh" "$PROJECT_DIRECTORY/backfort.sh" "$CONFIG_FILE"
wait_for_requests 1
TEMPLATE_TEXT=$(telegram_text)
grep -Fq '<b>Action for notify&lt;script&gt;&amp;</b>' <<<"$TEMPLATE_TEXT"
grep -Fq '&lt;script&gt;&amp; $(touch ' <<<"$TEMPLATE_TEXT"
grep -Fq '<code>sudo backfort.sh -c ' <<<"$TEMPLATE_TEXT"
[[ ! -e $PWN_FILE ]]

# %q keeps the recovery command copy-paste safe even when -c has spaces.
reset_requests
rm -rf -- "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
mkdir -p "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
SPACED_CONFIG_FILE="$TEST_DIRECTORY/config with spaces.yaml"
cp -- "$CONFIG_FILE" "$SPACED_CONFIG_FILE"
if PATH="$BIN_DIRECTORY/failing:$PATH" "$PROJECT_DIRECTORY/backfort.sh" -c "$SPACED_CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/spaced-config.err"; then
  exit 1
fi
wait_for_requests 1
SPACED_TEXT=$(telegram_text)
SPACED_BACKUP_ID=$(sed -n 's/.* restore \([^ ]*\) --to .*/\1/p' <<<"$SPACED_TEXT")
[[ $SPACED_BACKUP_ID =~ ^notify-host_notify_[0-9]{8}T[0-9]{6}Z_[A-Fa-f0-9]{8}$ ]]
printf -v EXPECTED_SPACED_HINT 'sudo backfort.sh -c %q restore %q --to %q' \
  "$SPACED_CONFIG_FILE" "$SPACED_BACKUP_ID" '/srv/restore-NOTIFY'
grep -Fq "$EXPECTED_SPACED_HINT" <<<"$SPACED_TEXT"

# A whitelist placeholder can be irrelevant to an event; it is safely blank.
reset_requests
rm -rf -- "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
mkdir -p "$STATE_DIRECTORY" "$BACKUP_DIRECTORY"
success_template_events='notifications:
  enabled: true
  channels:
    - name: ops-telegram
      type: telegram
      token_env: BACKFORT_TG_TOKEN
      chat_id_env: BACKFORT_TG_CHAT
      events: [success]
      templates:
        success: "target={{target}} done"'
write_config "$success_template_events"
"$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/template-success.err"
wait_for_requests 1
[[ $(telegram_text) == 'target= done' ]]

# Template validation fails before backup work or notification transport.
write_config "$telegram_events"
yq eval '.notifications.channels[0].templates = {"failure": "{{job}} {{nope}}"}' -i "$CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/template-unknown.err"; then exit 1; else [[ $? -eq 2 ]]; fi
grep -Fq 'channel=ops-telegram placeholder=nope' "$TEST_DIRECTORY/template-unknown.err"
yq eval '.notifications.channels[0].templates = {"smoke": "test"}' -i "$CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/template-event.err"; then exit 1; else [[ $? -eq 2 ]]; fi
LONG_TEMPLATE=$(printf 'x%.0s' {1..1500})
LONG_TEMPLATE="$LONG_TEMPLATE" yq eval '.notifications.channels[0].templates = {"failure": strenv(LONG_TEMPLATE)}' -i "$CONFIG_FILE"
if "$PROJECT_DIRECTORY/backfort.sh" -c "$CONFIG_FILE" run >/dev/null 2>"$TEST_DIRECTORY/template-length.err"; then exit 1; else [[ $? -eq 2 ]]; fi

# The maximum is enforced after substitution as well as on the YAML template.
reset_requests
write_config "$templated_telegram_events"
REPEATED_ERROR_TEMPLATE=''
for _ in {1..100}; do REPEATED_ERROR_TEMPLATE+='{{error}}'; done
REPEATED_ERROR_TEMPLATE="$REPEATED_ERROR_TEMPLATE" \
  yq eval '.notifications.channels[0].templates.failure = strenv(REPEATED_ERROR_TEMPLATE)' -i "$CONFIG_FILE"
LONG_ERROR=$(printf 'z.%.0s' {1..1500})
BACKFORT_EVENT_JOB=notify BACKFORT_EVENT_ID='notify-host_notify_20260925T021500Z_a91f3c2d' \
  BACKFORT_EVENT_ERROR="$LONG_ERROR" BACKFORT_EVENT_EXIT_CODE=3 \
  "$TEST_DIRECTORY/template-helper.sh" "$PROJECT_DIRECTORY/backfort.sh" "$CONFIG_FILE"
wait_for_requests 1
TRUNCATED_TEXT=$(telegram_text)
[[ ${#TRUNCATED_TEXT} -le 4096 && $TRUNCATED_TEXT == *... ]]

# Redaction is checked in a delivered JSON body, not only in stderr.
reset_requests
write_config "$webhook_events"
cat >"$TEST_DIRECTORY/redact-helper.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source <(head -n -1 "$1")
CONFIG_FILE=$2
check_yq
validate_config
initialize_notifications
bf_notify failure
EOF
chmod 0700 "$TEST_DIRECTORY/redact-helper.sh"
BACKFORT_EVENT_ERROR='TOKEN=abcdef1234567890abcdef1234567890 hex=0123456789abcdef0123456789abcdef' \
  BACKFORT_EVENT_JOB=notify BACKFORT_EVENT_STAGE=pack \
  "$TEST_DIRECTORY/redact-helper.sh" "$PROJECT_DIRECTORY/backfort.sh" "$CONFIG_FILE"
wait_for_requests 1
if grep -Fq 'abcdef1234567890abcdef1234567890' "$(latest_body)" \
  || grep -Fq '0123456789abcdef0123456789abcdef' "$(latest_body)"; then
  printf 'notification payload leaked a secret-like value\n' >&2
  exit 1
fi

printf 'Backfort notification test passed.\n'
