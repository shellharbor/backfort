#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C
umask 077

readonly BACKFORT_VERSION="0.1.0"

CONFIG_FILE="/etc/backfort/config.yaml"
DRY_RUN=false
COMMAND=""
SELECTED_JOB=""
SELECTED_DESTINATION=""
BACKUP_REFERENCE=""
VERIFY_MODE="quick"
RESTORE_DIRECTORY=""
JSON_OUTPUT=false

HOST_ID=""
STATE_DIRECTORY=""
TEMP_DIRECTORY=""
LOCK_FILE=""
MIN_FREE_MB=0
JOB_COUNT=0
DESTINATION_COUNT=0
WORK_DIRECTORY=""
LOCK_FD=""

usage() {
  cat <<'EOF'
Backfort 0.1.0 - one-shot backup and recovery for Linux

Usage:
  backfort.sh [-c FILE] [-n] run [--job NAME]
  backfort.sh [-c FILE] doctor [--job NAME]
  backfort.sh [-c FILE] list [--job NAME] [--json]
  backfort.sh [-c FILE] status [--job NAME]
  backfort.sh [-c FILE] verify BACKUP_ID [--from DEST] [--quick|--full]
  backfort.sh [-c FILE] verify latest --job NAME [--from DEST] [--quick|--full]
  backfort.sh [-c FILE] restore BACKUP_ID --to DIRECTORY [--from DEST]
  backfort.sh [-c FILE] restore latest --job NAME --to DIRECTORY [--from DEST]
  backfort.sh [-c FILE] [-n] prune [--job NAME]
  backfort.sh -V | --version

Exit codes:
  0  success
  1  at least one destination succeeded and at least one failed
  2  invalid arguments, configuration, dependencies, or environment
  3  operational failure or no usable backup copy
EOF
}

timestamp() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

log() {
  local level=$1
  shift
  printf '%s level=%s %s\n' "$(timestamp)" "$level" "$*" >&2
}

config_error() {
  log error "kind=config message=$*"
  exit 2
}

command_error() {
  log error "kind=usage message=$*"
  usage >&2
  exit 2
}

cleanup_work_directory() {
  if [[ -z ${WORK_DIRECTORY:-} || -z ${TEMP_DIRECTORY:-} ]]; then
    return 0
  fi

  case "$WORK_DIRECTORY" in
    "$TEMP_DIRECTORY"/backfort.*)
      rm -rf -- "$WORK_DIRECTORY"
      ;;
    *)
      log error "kind=safety message=refusing-to-remove-unexpected-work-directory"
      ;;
  esac
  WORK_DIRECTORY=""
}

on_exit() {
  cleanup_work_directory
}

on_interrupt() {
  log warning "kind=signal message=interrupted"
  exit 130
}

on_terminate() {
  log warning "kind=signal message=terminated"
  exit 143
}

trap on_exit EXIT
trap on_interrupt INT HUP
trap on_terminate TERM

require_command() {
  local name=$1
  if ! command -v "$name" >/dev/null 2>&1; then
    config_error "missing-command command=$name"
  fi
}

check_yq() {
  require_command yq
  local version
  version=$(yq --version 2>&1 || true)
  if [[ ! $version =~ version[[:space:]]+v?4\. ]]; then
    config_error "unsupported-yq expected=Mike-Farah-yq-v4"
  fi
}

cfg() {
  local expression=$1
  yq eval -r "$expression" "$CONFIG_FILE"
}

validate_identifier() {
  local kind=$1
  local value=$2
  if [[ ! $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    config_error "invalid-identifier kind=$kind value=$value"
  fi
}

validate_env_name() {
  local kind=$1
  local value=$2
  if [[ ! $value =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    config_error "invalid-environment-variable-name kind=$kind value=$value"
  fi
}

validate_integer() {
  local kind=$1
  local value=$2
  if [[ ! $value =~ ^[0-9]+$ ]]; then
    config_error "expected-non-negative-integer field=$kind value=$value"
  fi
}

validate_boolean() {
  local kind=$1
  local value=$2
  if [[ $value != true && $value != false ]]; then
    config_error "expected-boolean field=$kind value=$value"
  fi
}

validate_absolute_path() {
  local kind=$1
  local value=$2
  if [[ -z $value || $value != /* || $value == / || $value == *$'\n'* || $value == *$'\r'* \
    || $value == */../* || $value == */.. || $value == */./* || $value == */. ]]; then
    config_error "unsafe-path field=$kind"
  fi
}

validate_keys() {
  local expression=$1
  local allowed=" $2 "
  local key
  while IFS= read -r key; do
    if [[ $allowed != *" $key "* ]]; then
      config_error "unknown-config-key path=$expression key=$key"
    fi
  done < <(cfg "($expression) | keys | .[]")
}

find_destination_index() {
  local wanted=$1
  local index name
  for ((index = 0; index < DESTINATION_COUNT; index++)); do
    name=$(cfg ".destinations[$index].name")
    if [[ $name == "$wanted" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

find_job_index() {
  local wanted=$1
  local index name
  for ((index = 0; index < JOB_COUNT; index++)); do
    name=$(cfg ".jobs[$index].name")
    if [[ $name == "$wanted" ]]; then
      printf '%s\n' "$index"
      return 0
    fi
  done
  return 1
}

validate_config() {
  if [[ ! -f $CONFIG_FILE || ! -r $CONFIG_FILE ]]; then
    config_error "config-not-readable file=$CONFIG_FILE"
  fi

  if ! yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1; then
    config_error "invalid-yaml file=$CONFIG_FILE"
  fi

  validate_keys '.' 'version settings destinations jobs'

  local schema_version settings_type destinations_type jobs_type
  schema_version=$(cfg '.version // 0')
  settings_type=$(cfg '.settings | type')
  destinations_type=$(cfg '.destinations | type')
  jobs_type=$(cfg '.jobs | type')

  [[ $schema_version == 1 ]] || config_error "unsupported-schema-version value=$schema_version"
  [[ $settings_type == '!!map' ]] || config_error "settings-must-be-map"
  [[ $destinations_type == '!!seq' ]] || config_error "destinations-must-be-array"
  [[ $jobs_type == '!!seq' ]] || config_error "jobs-must-be-array"

  validate_keys '.settings' 'host_id state_directory temp_directory lock_file min_free_mb'

  HOST_ID=$(cfg '.settings.host_id // ""')
  STATE_DIRECTORY=$(cfg '.settings.state_directory // "/var/lib/backfort"')
  TEMP_DIRECTORY=$(cfg '.settings.temp_directory // "/var/tmp/backfort"')
  LOCK_FILE=$(cfg '.settings.lock_file // "/run/backfort.lock"')
  MIN_FREE_MB=$(cfg '.settings.min_free_mb // 0')

  validate_identifier host_id "$HOST_ID"
  validate_absolute_path settings.state_directory "$STATE_DIRECTORY"
  validate_absolute_path settings.temp_directory "$TEMP_DIRECTORY"
  validate_absolute_path settings.lock_file "$LOCK_FILE"
  validate_integer settings.min_free_mb "$MIN_FREE_MB"

  DESTINATION_COUNT=$(cfg '.destinations | length')
  JOB_COUNT=$(cfg '.jobs | length')
  validate_integer destinations.length "$DESTINATION_COUNT"
  validate_integer jobs.length "$JOB_COUNT"
  ((DESTINATION_COUNT > 0)) || config_error "at-least-one-destination-required"
  ((JOB_COUNT > 0)) || config_error "at-least-one-job-required"

  local index other name type path other_name
  for ((index = 0; index < DESTINATION_COUNT; index++)); do
    validate_keys ".destinations[$index]" 'name type path'
    name=$(cfg ".destinations[$index].name // \"\"")
    type=$(cfg ".destinations[$index].type // \"\"")
    path=$(cfg ".destinations[$index].path // \"\"")
    validate_identifier destination "$name"
    [[ $type == local ]] || config_error "unsupported-destination-type destination=$name type=$type"
    validate_absolute_path "destinations[$index].path" "$path"

    for ((other = 0; other < index; other++)); do
      other_name=$(cfg ".destinations[$other].name")
      [[ $name != "$other_name" ]] || config_error "duplicate-destination name=$name"
    done
  done

  local source_type paths_count destinations_count compression compression_level exclude_count exclude_index exclude
  local encryption keep_last keep_daily keep_weekly keep_monthly follow_symlinks
  local destination_name path_index destination_index env_name

  for ((index = 0; index < JOB_COUNT; index++)); do
    validate_keys ".jobs[$index]" 'name source destinations compression encryption retention'
    name=$(cfg ".jobs[$index].name // \"\"")
    validate_identifier job "$name"

    for ((other = 0; other < index; other++)); do
      other_name=$(cfg ".jobs[$other].name")
      [[ $name != "$other_name" ]] || config_error "duplicate-job name=$name"
    done

    [[ $(cfg ".jobs[$index].source | type") == '!!map' ]] || config_error "source-must-be-map job=$name"
    validate_keys ".jobs[$index].source" 'type paths exclude follow_symlinks'
    source_type=$(cfg ".jobs[$index].source.type // \"\"")
    [[ $source_type == files ]] || config_error "unsupported-source-type job=$name type=$source_type"
    [[ $(cfg ".jobs[$index].source.paths | type") == '!!seq' ]] || config_error "source-paths-must-be-array job=$name"
    paths_count=$(cfg ".jobs[$index].source.paths | length")
    validate_integer "jobs[$index].source.paths.length" "$paths_count"
    ((paths_count > 0)) || config_error "source-paths-empty job=$name"
    for ((path_index = 0; path_index < paths_count; path_index++)); do
      path=$(cfg ".jobs[$index].source.paths[$path_index]")
      validate_absolute_path "jobs[$index].source.paths[$path_index]" "$path"
    done

    if [[ $(cfg "(.jobs[$index].source.exclude // []) | type") != '!!seq' ]]; then
      config_error "source-exclude-must-be-array job=$name"
    fi
    exclude_count=$(cfg ".jobs[$index].source.exclude // [] | length")
    for ((exclude_index = 0; exclude_index < exclude_count; exclude_index++)); do
      exclude=$(cfg ".jobs[$index].source.exclude[$exclude_index]")
      if [[ $exclude == *$'\n'* || $exclude == *$'\r'* ]]; then
        config_error "newline-in-exclude-pattern job=$name index=$exclude_index"
      fi
    done
    follow_symlinks=$(cfg ".jobs[$index].source.follow_symlinks // false")
    validate_boolean "jobs[$index].source.follow_symlinks" "$follow_symlinks"

    [[ $(cfg ".jobs[$index].destinations | type") == '!!seq' ]] || config_error "job-destinations-must-be-array job=$name"
    destinations_count=$(cfg ".jobs[$index].destinations | length")
    validate_integer "jobs[$index].destinations.length" "$destinations_count"
    ((destinations_count > 0)) || config_error "job-destinations-empty job=$name"
    for ((other = 0; other < destinations_count; other++)); do
      destination_name=$(cfg ".jobs[$index].destinations[$other]")
      validate_identifier destination-reference "$destination_name"
      if ! destination_index=$(find_destination_index "$destination_name"); then
        config_error "unknown-destination job=$name destination=$destination_name"
      fi
      : "$destination_index"
      local earlier earlier_destination
      for ((earlier = 0; earlier < other; earlier++)); do
        earlier_destination=$(cfg ".jobs[$index].destinations[$earlier]")
        [[ $destination_name != "$earlier_destination" ]] || config_error "duplicate-job-destination job=$name destination=$destination_name"
      done
    done

    if [[ $(cfg "(.jobs[$index].compression // {}) | type") != '!!map' ]]; then
      config_error "compression-must-be-map job=$name"
    fi
    validate_keys ".jobs[$index].compression // {}" 'method level'
    compression=$(cfg ".jobs[$index].compression.method // \"gzip\"")
    compression_level=$(cfg ".jobs[$index].compression.level // 6")
    [[ $compression == gzip || $compression == zstd || $compression == none ]] || config_error "unsupported-compression job=$name method=$compression"
    validate_integer "jobs[$index].compression.level" "$compression_level"
    case "$compression" in
      gzip) ((compression_level >= 1 && compression_level <= 9)) || config_error "gzip-level-out-of-range job=$name" ;;
      zstd) ((compression_level >= 1 && compression_level <= 19)) || config_error "zstd-level-out-of-range job=$name" ;;
      none) : ;;
    esac

    if [[ $(cfg "(.jobs[$index].encryption // {}) | type") != '!!map' ]]; then
      config_error "encryption-must-be-map job=$name"
    fi
    validate_keys ".jobs[$index].encryption // {}" 'method recipient_env identity_file_env password_env'
    encryption=$(cfg ".jobs[$index].encryption.method // \"none\"")
    [[ $encryption == none || $encryption == age || $encryption == gpg ]] || config_error "unsupported-encryption job=$name method=$encryption"
    if [[ $encryption == age ]]; then
      env_name=$(cfg ".jobs[$index].encryption.recipient_env // \"\"")
      validate_env_name "jobs[$index].encryption.recipient_env" "$env_name"
      env_name=$(cfg ".jobs[$index].encryption.identity_file_env // \"\"")
      if [[ -n $env_name ]]; then
        validate_env_name "jobs[$index].encryption.identity_file_env" "$env_name"
      fi
    elif [[ $encryption == gpg ]]; then
      env_name=$(cfg ".jobs[$index].encryption.password_env // \"\"")
      validate_env_name "jobs[$index].encryption.password_env" "$env_name"
    fi

    if [[ $(cfg "(.jobs[$index].retention // {}) | type") != '!!map' ]]; then
      config_error "retention-must-be-map job=$name"
    fi
    validate_keys ".jobs[$index].retention // {}" 'keep_last keep_daily keep_weekly keep_monthly'
    keep_last=$(cfg ".jobs[$index].retention.keep_last // 3")
    keep_daily=$(cfg ".jobs[$index].retention.keep_daily // 0")
    keep_weekly=$(cfg ".jobs[$index].retention.keep_weekly // 0")
    keep_monthly=$(cfg ".jobs[$index].retention.keep_monthly // 0")
    validate_integer "jobs[$index].retention.keep_last" "$keep_last"
    validate_integer "jobs[$index].retention.keep_daily" "$keep_daily"
    validate_integer "jobs[$index].retention.keep_weekly" "$keep_weekly"
    validate_integer "jobs[$index].retention.keep_monthly" "$keep_monthly"
    ((keep_last > 0)) || config_error "keep-last-must-be-positive job=$name"
  done

  if [[ -n $SELECTED_JOB ]]; then
    validate_identifier selected_job "$SELECTED_JOB"
    if ! find_job_index "$SELECTED_JOB" >/dev/null; then
      config_error "unknown-selected-job job=$SELECTED_JOB"
    fi
  fi
  if [[ -n $SELECTED_DESTINATION ]]; then
    validate_identifier selected_destination "$SELECTED_DESTINATION"
    if ! find_destination_index "$SELECTED_DESTINATION" >/dev/null; then
      config_error "unknown-selected-destination destination=$SELECTED_DESTINATION"
    fi
  fi
}

nearest_existing_directory() {
  local candidate=$1
  while [[ ! -d $candidate ]]; do
    local parent
    parent=$(dirname -- "$candidate")
    [[ $parent != "$candidate" ]] || return 1
    candidate=$parent
  done
  printf '%s\n' "$candidate"
}

check_free_space() {
  local target=$1
  local label=$2
  ((MIN_FREE_MB == 0)) && return 0

  local existing available_kb required_kb
  if ! existing=$(nearest_existing_directory "$target"); then
    config_error "no-existing-parent field=$label"
  fi
  available_kb=$(df -Pk -- "$existing" | awk 'NR == 2 {print $4}')
  validate_integer "$label.available-kb" "$available_kb"
  required_kb=$((MIN_FREE_MB * 1024))
  if ((available_kb < required_kb)); then
    config_error "insufficient-free-space field=$label required_mb=$MIN_FREE_MB"
  fi
}

path_is_within() {
  local child=$1
  local parent=$2
  [[ "$child/" == "$parent/"* ]]
}

preflight_job() {
  local index=$1
  local name compression encryption env_name env_value
  local path paths_count path_index canonical_source canonical_target
  local destination_count destination_name destination_position destination_index destination_path

  name=$(cfg ".jobs[$index].name")
  compression=$(cfg ".jobs[$index].compression.method // \"gzip\"")
  encryption=$(cfg ".jobs[$index].encryption.method // \"none\"")

  require_command tar
  require_command sha256sum
  require_command realpath
  require_command find
  require_command sort
  require_command date
  require_command df
  require_command awk
  require_command basename
  require_command chmod
  require_command cp
  require_command dirname
  require_command flock
  require_command mkdir
  require_command mktemp
  require_command mv
  require_command rm
  case "$compression" in
    gzip) require_command gzip ;;
    zstd) require_command zstd ;;
  esac
  case "$encryption" in
    age)
      require_command age
      env_name=$(cfg ".jobs[$index].encryption.recipient_env")
      env_value=${!env_name-}
      [[ -n $env_value ]] || config_error "missing-environment-variable job=$name variable=$env_name"
      ;;
    gpg)
      require_command gpg
      env_name=$(cfg ".jobs[$index].encryption.password_env")
      env_value=${!env_name-}
      [[ -n $env_value ]] || config_error "missing-environment-variable job=$name variable=$env_name"
      ;;
  esac

  paths_count=$(cfg ".jobs[$index].source.paths | length")
  destination_count=$(cfg ".jobs[$index].destinations | length")
  for ((path_index = 0; path_index < paths_count; path_index++)); do
    path=$(cfg ".jobs[$index].source.paths[$path_index]")
    [[ -e $path || -L $path ]] || config_error "source-does-not-exist job=$name path-index=$path_index"
    [[ -r $path ]] || config_error "source-not-readable job=$name path-index=$path_index"
    canonical_source=$(realpath -e -- "$path")

    if [[ -d $path ]]; then
      canonical_target=$(realpath -m -- "$TEMP_DIRECTORY")
      path_is_within "$canonical_target" "$canonical_source" && config_error "temp-directory-inside-source job=$name path-index=$path_index"
      canonical_target=$(realpath -m -- "$STATE_DIRECTORY")
      path_is_within "$canonical_target" "$canonical_source" && config_error "state-directory-inside-source job=$name path-index=$path_index"
      canonical_target=$(realpath -m -- "$LOCK_FILE")
      path_is_within "$canonical_target" "$canonical_source" && config_error "lock-file-inside-source job=$name path-index=$path_index"

      for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
        destination_name=$(cfg ".jobs[$index].destinations[$destination_position]")
        destination_index=$(find_destination_index "$destination_name")
        destination_path=$(cfg ".destinations[$destination_index].path")
        canonical_target=$(realpath -m -- "$destination_path")
        path_is_within "$canonical_target" "$canonical_source" && config_error "destination-inside-source job=$name destination=$destination_name"
      done
    fi
  done

  local existing
  existing=$(nearest_existing_directory "$TEMP_DIRECTORY") || config_error "temp-directory-has-no-parent"
  [[ -w $existing ]] || config_error "temp-directory-parent-not-writable path=$existing"
  check_free_space "$TEMP_DIRECTORY" settings.temp_directory

  for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
    destination_name=$(cfg ".jobs[$index].destinations[$destination_position]")
    local resolved_index
    resolved_index=$(find_destination_index "$destination_name")
    destination_path=$(cfg ".destinations[$resolved_index].path")
    existing=$(nearest_existing_directory "$destination_path") || config_error "destination-has-no-parent destination=$destination_name"
    [[ -w $existing ]] || config_error "destination-parent-not-writable destination=$destination_name path=$existing"
    check_free_space "$destination_path" "destination.$destination_name"
  done
}

preflight_selected_jobs() {
  local index name
  for ((index = 0; index < JOB_COUNT; index++)); do
    name=$(cfg ".jobs[$index].name")
    [[ -z $SELECTED_JOB || $name == "$SELECTED_JOB" ]] || continue
    preflight_job "$index"
  done
}

ensure_runtime_directories() {
  mkdir -p -- "$STATE_DIRECTORY" "$TEMP_DIRECTORY" "$(dirname -- "$LOCK_FILE")"
  chmod 0700 "$STATE_DIRECTORY" "$TEMP_DIRECTORY"
}

acquire_lock() {
  ensure_runtime_directories
  exec {LOCK_FD}>"$LOCK_FILE"
  if ! flock -n "$LOCK_FD"; then
    log error "kind=lock message=another-run-is-active"
    return 3
  fi
}

make_work_directory() {
  cleanup_work_directory
  WORK_DIRECTORY=$(mktemp -d "$TEMP_DIRECTORY/backfort.XXXXXXXX")
}

new_backup_id() {
  local job=$1
  local created_compact random_part
  created_compact=$(date -u +'%Y%m%dT%H%M%SZ')
  random_part=$(printf '%08x' "$(( (10#$(date -u +%s) ^ $$ ^ RANDOM ^ (RANDOM << 8)) & 0xffffffff ))")
  printf '%s_%s_%s_%s\n' "$HOST_ID" "$job" "$created_compact" "$random_part"
}

artifact_extensions() {
  local compression=$1
  local encryption=$2
  local result
  case "$compression" in
    gzip) result='.tar.gz' ;;
    zstd) result='.tar.zst' ;;
    none) result='.tar' ;;
  esac
  case "$encryption" in
    age) result+='.age' ;;
    gpg) result+='.gpg' ;;
  esac
  printf '%s\n' "$result"
}

create_manifest() {
  local job_index=$1
  local backup_id=$2
  local created_at=$3
  local payload_name=$4
  local output=$5

  BF_MANIFEST_VERSION=$BACKFORT_VERSION \
  BF_MANIFEST_ID=$backup_id \
  BF_MANIFEST_HOST=$HOST_ID \
  BF_MANIFEST_CREATED=$created_at \
  BF_MANIFEST_PAYLOAD=$payload_name \
    yq eval -o=json -I=2 ".jobs[$job_index] | {
      \"schema_version\": 1,
      \"backfort_version\": strenv(BF_MANIFEST_VERSION),
      \"backup_id\": strenv(BF_MANIFEST_ID),
      \"host_id\": strenv(BF_MANIFEST_HOST),
      \"job\": .name,
      \"created_at\": strenv(BF_MANIFEST_CREATED),
      \"payload_file\": strenv(BF_MANIFEST_PAYLOAD),
      \"source\": .source,
      \"destinations\": .destinations,
      \"compression\": (.compression // {\"method\": \"gzip\", \"level\": 6}),
      \"encryption\": (.encryption // {\"method\": \"none\"})
    }" "$CONFIG_FILE" >"$output"
}

pack_job() {
  local job_index=$1
  local tar_file=$2
  local manifest=$3
  local list_file="$WORK_DIRECTORY/source-paths.list"
  local paths_count path_index path exclude_count exclude_index exclude follow_symlinks
  local -a tar_arguments

  if ! tar --create --file "$tar_file" --directory "$WORK_DIRECTORY" "$(basename -- "$manifest")"; then
    log error "kind=pack message=manifest-pack-failed"
    return 3
  fi

  paths_count=$(cfg ".jobs[$job_index].source.paths | length")
  : >"$list_file"
  for ((path_index = 0; path_index < paths_count; path_index++)); do
    path=$(cfg ".jobs[$job_index].source.paths[$path_index]")
    printf '%s\0' "${path#/}" >>"$list_file"
  done

  tar_arguments=(--append --file "$tar_file" --directory / --transform 's,^,data/,')
  follow_symlinks=$(cfg ".jobs[$job_index].source.follow_symlinks // false")
  [[ $follow_symlinks == true ]] && tar_arguments+=(--dereference)

  exclude_count=$(cfg ".jobs[$job_index].source.exclude // [] | length")
  for ((exclude_index = 0; exclude_index < exclude_count; exclude_index++)); do
    exclude=$(cfg ".jobs[$job_index].source.exclude[$exclude_index]")
    [[ $exclude != *$'\n'* && $exclude != *$'\r'* ]] || config_error "newline-in-exclude-pattern"
    tar_arguments+=("--exclude=$exclude")
  done
  tar_arguments+=(--null --files-from "$list_file")

  if ! tar "${tar_arguments[@]}"; then
    log error "kind=pack message=source-pack-failed"
    return 3
  fi
}

compress_tar() {
  local method=$1
  local level=$2
  local input=$3
  local output=$4

  case "$method" in
    gzip)
      gzip "-$level" -c -- "$input" >"$output"
      ;;
    zstd)
      zstd -q "-$level" -c -- "$input" >"$output"
      ;;
    none)
      cp -- "$input" "$output"
      ;;
  esac
}

encrypt_artifact() {
  local method=$1
  local job_index=$2
  local input=$3
  local output=$4
  local env_name secret

  case "$method" in
    none)
      [[ $input == "$output" ]] || cp -- "$input" "$output"
      ;;
    age)
      env_name=$(cfg ".jobs[$job_index].encryption.recipient_env")
      secret=${!env_name-}
      if ! age --encrypt --recipient "$secret" --output "$output" "$input"; then
        secret=""
        return 3
      fi
      secret=""
      ;;
    gpg)
      env_name=$(cfg ".jobs[$job_index].encryption.password_env")
      secret=${!env_name-}
      if ! gpg --batch --yes --pinentry-mode loopback --cipher-algo AES256 --compress-algo none \
        --passphrase-fd 3 --symmetric --output "$output" "$input" 3<<<"$secret"; then
        secret=""
        return 3
      fi
      secret=""
      ;;
  esac
}

atomic_copy() {
  local source=$1
  local destination=$2
  local temporary="${destination}.partial.$$"
  rm -f -- "$temporary"
  cp -- "$source" "$temporary" && mv -- "$temporary" "$destination"
}

publish_to_destination() {
  local destination_index=$1
  local backup_id=$2
  local payload=$3
  local metadata=$4
  local checksum=$5
  local destination_name destination_path payload_name
  local final_payload final_metadata final_checksum final_complete marker_source

  destination_name=$(cfg ".destinations[$destination_index].name")
  destination_path=$(cfg ".destinations[$destination_index].path")
  payload_name=$(basename -- "$payload")
  final_payload="$destination_path/$payload_name"
  final_metadata="$destination_path/$backup_id.metadata.json"
  final_checksum="$destination_path/$backup_id.sha256"
  final_complete="$destination_path/$backup_id.complete"
  marker_source="$WORK_DIRECTORY/$backup_id.complete"

  if ! mkdir -p -- "$destination_path"; then
    log error "kind=publish destination=$destination_name message=create-directory-failed"
    return 3
  fi
  if [[ -e $final_payload || -e $final_metadata || -e $final_checksum || -e $final_complete ]]; then
    log error "kind=publish destination=$destination_name message=backup-id-already-exists"
    return 3
  fi

  printf '%s\n' "$backup_id" >"$marker_source"
  if atomic_copy "$payload" "$final_payload" \
    && atomic_copy "$metadata" "$final_metadata" \
    && atomic_copy "$checksum" "$final_checksum" \
    && atomic_copy "$marker_source" "$final_complete"; then
    log info "event=backup-published destination=$destination_name backup_id=$backup_id"
    return 0
  fi

  rm -f -- "$final_payload" "$final_metadata" "$final_checksum" "$final_complete"
  rm -f -- "$destination_path/$payload_name.partial.$$" \
    "$destination_path/$backup_id.metadata.json.partial.$$" \
    "$destination_path/$backup_id.sha256.partial.$$" \
    "$destination_path/$backup_id.complete.partial.$$"
  log error "kind=publish destination=$destination_name message=atomic-publish-failed"
  return 3
}

run_job() {
  local job_index=$1
  local job_name compression compression_level encryption created_at backup_id extension
  local manifest tar_file compressed_file payload_file checksum_file payload_name hash
  local destination_count destination_position destination_name destination_index
  local successful=0 failed=0

  job_name=$(cfg ".jobs[$job_index].name")
  compression=$(cfg ".jobs[$job_index].compression.method // \"gzip\"")
  compression_level=$(cfg ".jobs[$job_index].compression.level // 6")
  encryption=$(cfg ".jobs[$job_index].encryption.method // \"none\"")

  if [[ $DRY_RUN == true ]]; then
    log info "event=plan job=$job_name source=files compression=$compression encryption=$encryption"
    destination_count=$(cfg ".jobs[$job_index].destinations | length")
    for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
      destination_name=$(cfg ".jobs[$job_index].destinations[$destination_position]")
      log info "event=plan-publish job=$job_name destination=$destination_name"
    done
    return 0
  fi

  make_work_directory
  created_at=$(timestamp)
  backup_id=$(new_backup_id "$job_name")
  extension=$(artifact_extensions "$compression" "$encryption")
  payload_name="$backup_id$extension"
  manifest="$WORK_DIRECTORY/manifest.json"
  tar_file="$WORK_DIRECTORY/$backup_id.tar"

  case "$compression" in
    gzip) compressed_file="$WORK_DIRECTORY/$backup_id.tar.gz" ;;
    zstd) compressed_file="$WORK_DIRECTORY/$backup_id.tar.zst" ;;
    none) compressed_file="$tar_file" ;;
  esac
  payload_file="$WORK_DIRECTORY/$payload_name"
  checksum_file="$WORK_DIRECTORY/$backup_id.sha256"

  log info "event=backup-started job=$job_name backup_id=$backup_id"
  if ! create_manifest "$job_index" "$backup_id" "$created_at" "$payload_name" "$manifest"; then
    log error "kind=manifest job=$job_name message=create-failed"
    cleanup_work_directory
    return 3
  fi
  if ! pack_job "$job_index" "$tar_file" "$manifest"; then
    cleanup_work_directory
    return 3
  fi

  if [[ $compression != none ]]; then
    if ! compress_tar "$compression" "$compression_level" "$tar_file" "$compressed_file"; then
      log error "kind=compress job=$job_name method=$compression message=failed"
      cleanup_work_directory
      return 3
    fi
    rm -f -- "$tar_file"
  fi

  if [[ $encryption != none ]]; then
    if ! encrypt_artifact "$encryption" "$job_index" "$compressed_file" "$payload_file"; then
      log error "kind=encrypt job=$job_name method=$encryption message=failed"
      cleanup_work_directory
      return 3
    fi
    rm -f -- "$compressed_file"
  fi

  hash=$(sha256sum "$payload_file" | awk '{print $1}')
  printf '%s  %s\n' "$hash" "$payload_name" >"$checksum_file"

  destination_count=$(cfg ".jobs[$job_index].destinations | length")
  for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
    destination_name=$(cfg ".jobs[$job_index].destinations[$destination_position]")
    destination_index=$(find_destination_index "$destination_name")
    if publish_to_destination "$destination_index" "$backup_id" "$payload_file" "$manifest" "$checksum_file"; then
      successful=$((successful + 1))
    else
      failed=$((failed + 1))
    fi
  done

  cleanup_work_directory
  if ((successful == 0)); then
    log error "event=backup-failed job=$job_name backup_id=$backup_id reason=no-destination-succeeded"
    return 3
  fi
  if ((failed > 0)); then
    log warning "event=backup-partial job=$job_name backup_id=$backup_id successful=$successful failed=$failed"
    return 1
  fi
  log info "event=backup-succeeded job=$job_name backup_id=$backup_id destinations=$successful"
  return 0
}

run_command() {
  preflight_selected_jobs
  if [[ $DRY_RUN == false ]]; then
    require_command flock
    if ! acquire_lock; then
      return 3
    fi
  fi

  local index name result=0 job_result
  for ((index = 0; index < JOB_COUNT; index++)); do
    name=$(cfg ".jobs[$index].name")
    [[ -z $SELECTED_JOB || $name == "$SELECTED_JOB" ]] || continue
    if run_job "$index"; then
      job_result=0
    else
      job_result=$?
    fi
    if ((job_result == 3)); then
      result=3
    elif ((job_result == 1 && result == 0)); then
      result=1
    fi
  done
  return "$result"
}

metadata_value() {
  local file=$1
  local expression=$2
  yq eval -r "$expression" "$file"
}

validate_backup_bundle() {
  local directory=$1
  local backup_id=$2
  local metadata="$directory/$backup_id.metadata.json"
  local checksum="$directory/$backup_id.sha256"
  local complete="$directory/$backup_id.complete"
  local payload metadata_id marker_id

  validate_identifier backup_id "$backup_id"
  [[ -f $complete && ! -L $complete && -f $metadata && ! -L $metadata \
    && -f $checksum && ! -L $checksum ]] || return 1
  IFS= read -r marker_id <"$complete"
  [[ $marker_id == "$backup_id" ]] || return 1
  metadata_id=$(metadata_value "$metadata" '.backup_id // ""')
  [[ $metadata_id == "$backup_id" ]] || return 1
  payload=$(metadata_value "$metadata" '.payload_file // ""')
  [[ $payload == "$backup_id".* && $payload != */* && $payload != *$'\n'* ]] || return 1
  [[ -f $directory/$payload && ! -L $directory/$payload ]] || return 1
  return 0
}

iterate_destination_markers() {
  local destination_path=$1
  find "$destination_path" -maxdepth 1 -type f -name '*.complete' -print0 2>/dev/null | sort -zr
}

list_command() {
  local destination_index destination_name destination_path marker backup_id metadata job created payload
  local first_json=true
  [[ $JSON_OUTPUT == true ]] && printf '[\n'

  for ((destination_index = 0; destination_index < DESTINATION_COUNT; destination_index++)); do
    destination_name=$(cfg ".destinations[$destination_index].name")
    destination_path=$(cfg ".destinations[$destination_index].path")
    [[ -d $destination_path ]] || continue

    while IFS= read -r -d '' marker; do
      backup_id=$(basename -- "$marker" .complete)
      validate_identifier backup_id "$backup_id"
      if ! validate_backup_bundle "$destination_path" "$backup_id"; then
        log warning "kind=bundle destination=$destination_name backup_id=$backup_id message=incomplete-or-invalid"
        continue
      fi
      metadata="$destination_path/$backup_id.metadata.json"
      job=$(metadata_value "$metadata" '.job // ""')
      [[ -z $SELECTED_JOB || $job == "$SELECTED_JOB" ]] || continue
      created=$(metadata_value "$metadata" '.created_at // ""')
      payload=$(metadata_value "$metadata" '.payload_file // ""')

      if [[ $JSON_OUTPUT == true ]]; then
        [[ $first_json == true ]] || printf ',\n'
        BF_LIST_DESTINATION=$destination_name yq eval -o=json -I=2 \
          '. + {"destination": strenv(BF_LIST_DESTINATION)}' "$metadata"
        first_json=false
      else
        printf '%s\t%s\t%s\t%s\t%s\n' "$created" "$job" "$destination_name" "$backup_id" "$payload"
      fi
    done < <(iterate_destination_markers "$destination_path")
  done

  [[ $JSON_OUTPUT == true ]] && printf '\n]\n'
  return 0
}

status_command() {
  local job_index job destination_position destination_count destination_name destination_index destination_path
  local marker backup_id metadata created found
  printf 'JOB\tDESTINATION\tLATEST\tBACKUP_ID\n'

  for ((job_index = 0; job_index < JOB_COUNT; job_index++)); do
    job=$(cfg ".jobs[$job_index].name")
    [[ -z $SELECTED_JOB || $job == "$SELECTED_JOB" ]] || continue
    destination_count=$(cfg ".jobs[$job_index].destinations | length")
    for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
      destination_name=$(cfg ".jobs[$job_index].destinations[$destination_position]")
      destination_index=$(find_destination_index "$destination_name")
      destination_path=$(cfg ".destinations[$destination_index].path")
      found=false
      if [[ -d $destination_path ]]; then
        while IFS= read -r -d '' marker; do
          backup_id=$(basename -- "$marker" .complete)
          validate_identifier backup_id "$backup_id"
          validate_backup_bundle "$destination_path" "$backup_id" || continue
          metadata="$destination_path/$backup_id.metadata.json"
          [[ $(metadata_value "$metadata" '.job // ""') == "$job" ]] || continue
          created=$(metadata_value "$metadata" '.created_at // ""')
          printf '%s\t%s\t%s\t%s\n' "$job" "$destination_name" "$created" "$backup_id"
          found=true
          break
        done < <(iterate_destination_markers "$destination_path")
      fi
      [[ $found == true ]] || printf '%s\t%s\t%s\t%s\n' "$job" "$destination_name" 'never' '-'
    done
  done
}

BACKUP_DESTINATION_NAME=""
BACKUP_ID=""
BACKUP_METADATA=""
BACKUP_CHECKSUM=""
BACKUP_PAYLOAD=""

select_backup() {
  local reference=$1
  local destination_index destination_name destination_path marker backup_id metadata job created
  local chosen_created="" chosen_id="" chosen_path="" chosen_destination=""

  if [[ $reference != latest ]]; then
    validate_identifier backup_id "$reference"
  elif [[ -z $SELECTED_JOB ]]; then
    config_error "latest-requires-job-selection"
  fi

  for ((destination_index = 0; destination_index < DESTINATION_COUNT; destination_index++)); do
    destination_name=$(cfg ".destinations[$destination_index].name")
    [[ -z $SELECTED_DESTINATION || $destination_name == "$SELECTED_DESTINATION" ]] || continue
    destination_path=$(cfg ".destinations[$destination_index].path")
    [[ -d $destination_path ]] || continue

    if [[ $reference != latest ]]; then
      if validate_backup_bundle "$destination_path" "$reference"; then
        if [[ -n $SELECTED_JOB ]]; then
          metadata="$destination_path/$reference.metadata.json"
          [[ $(metadata_value "$metadata" '.job // ""') == "$SELECTED_JOB" ]] || continue
        fi
        chosen_id=$reference
        chosen_path=$destination_path
        chosen_destination=$destination_name
        break
      fi
      continue
    fi

    while IFS= read -r -d '' marker; do
      backup_id=$(basename -- "$marker" .complete)
      validate_identifier backup_id "$backup_id"
      validate_backup_bundle "$destination_path" "$backup_id" || continue
      metadata="$destination_path/$backup_id.metadata.json"
      job=$(metadata_value "$metadata" '.job // ""')
      [[ $job == "$SELECTED_JOB" ]] || continue
      created=$(metadata_value "$metadata" '.created_at // ""')
      if [[ -z $chosen_created || $created > $chosen_created ]]; then
        chosen_created=$created
        chosen_id=$backup_id
        chosen_path=$destination_path
        chosen_destination=$destination_name
      fi
    done < <(iterate_destination_markers "$destination_path")
  done

  if [[ -z $chosen_id ]]; then
    log error "kind=lookup message=backup-not-found reference=$reference"
    return 3
  fi

  BACKUP_DESTINATION_NAME=$chosen_destination
  BACKUP_ID=$chosen_id
  BACKUP_METADATA="$chosen_path/$chosen_id.metadata.json"
  BACKUP_CHECKSUM="$chosen_path/$chosen_id.sha256"
  local payload_name
  payload_name=$(metadata_value "$BACKUP_METADATA" '.payload_file')
  BACKUP_PAYLOAD="$chosen_path/$payload_name"
}

verify_checksum() {
  local expected checksum_name actual payload_name
  IFS=' ' read -r expected checksum_name <"$BACKUP_CHECKSUM"
  payload_name=$(basename -- "$BACKUP_PAYLOAD")
  if [[ ! $expected =~ ^[a-f0-9]{64}$ || $checksum_name != "$payload_name" ]]; then
    log error "kind=verify backup_id=$BACKUP_ID message=invalid-checksum-file"
    return 3
  fi
  actual=$(sha256sum "$BACKUP_PAYLOAD" | awk '{print $1}')
  if [[ $actual != "$expected" ]]; then
    log error "kind=verify backup_id=$BACKUP_ID message=checksum-mismatch"
    return 3
  fi
}

decrypt_artifact() {
  local method=$1
  local input=$2
  local output=$3
  local env_name secret identity_file

  case "$method" in
    none)
      cp -- "$input" "$output"
      ;;
    age)
      require_command age
      env_name=$(metadata_value "$BACKUP_METADATA" '.encryption.identity_file_env // ""')
      [[ -n $env_name ]] || config_error "age-identity-file-env-not-recorded backup_id=$BACKUP_ID"
      validate_env_name encryption.identity_file_env "$env_name"
      identity_file=${!env_name-}
      [[ -n $identity_file && -r $identity_file ]] || config_error "age-identity-file-not-readable variable=$env_name"
      age --decrypt --identity "$identity_file" --output "$output" "$input"
      ;;
    gpg)
      require_command gpg
      env_name=$(metadata_value "$BACKUP_METADATA" '.encryption.password_env // ""')
      validate_env_name encryption.password_env "$env_name"
      secret=${!env_name-}
      [[ -n $secret ]] || config_error "missing-environment-variable variable=$env_name"
      gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 \
        --decrypt --output "$output" "$input" 3<<<"$secret"
      secret=""
      ;;
    *)
      log error "kind=verify backup_id=$BACKUP_ID message=unknown-encryption-method"
      return 3
      ;;
  esac
}

prepare_tar() {
  local encryption compression decrypted tar_file entries verbose_entries internal_manifest
  encryption=$(metadata_value "$BACKUP_METADATA" '.encryption.method // "none"')
  compression=$(metadata_value "$BACKUP_METADATA" '.compression.method // "gzip"')
  decrypted="$WORK_DIRECTORY/decrypted"
  tar_file="$WORK_DIRECTORY/backup.tar"
  entries="$WORK_DIRECTORY/archive.entries"
  verbose_entries="$WORK_DIRECTORY/archive.verbose"
  internal_manifest="$WORK_DIRECTORY/internal-manifest.json"

  if ! decrypt_artifact "$encryption" "$BACKUP_PAYLOAD" "$decrypted"; then
    log error "kind=verify backup_id=$BACKUP_ID message=decryption-failed"
    return 3
  fi

  case "$compression" in
    gzip)
      require_command gzip
      gzip -dc -- "$decrypted" >"$tar_file" || return 3
      ;;
    zstd)
      require_command zstd
      zstd -q -dc -- "$decrypted" >"$tar_file" || return 3
      ;;
    none)
      cp -- "$decrypted" "$tar_file" || return 3
      ;;
    *)
      log error "kind=verify backup_id=$BACKUP_ID message=unknown-compression-method"
      return 3
      ;;
  esac

  if ! tar --list --file "$tar_file" --quoting-style=escape >"$entries" \
    || ! tar --list --verbose --file "$tar_file" --quoting-style=escape >"$verbose_entries"; then
    log error "kind=verify backup_id=$BACKUP_ID message=invalid-tar"
    return 3
  fi

  local entry line entry_type
  while IFS= read -r entry; do
    if [[ $entry != manifest.json && $entry != data/* ]]; then
      log error "kind=verify backup_id=$BACKUP_ID message=unsafe-archive-path"
      return 3
    fi
    if [[ $entry == /* || $entry == ../* || $entry == *'/../'* || $entry == *'/..' ]]; then
      log error "kind=verify backup_id=$BACKUP_ID message=unsafe-archive-path"
      return 3
    fi
  done <"$entries"

  while IFS= read -r line; do
    entry_type=${line:0:1}
    case "$entry_type" in
      -|d|l|h) : ;;
      *)
        log error "kind=verify backup_id=$BACKUP_ID message=unsupported-archive-entry-type type=$entry_type"
        return 3
        ;;
    esac
  done <"$verbose_entries"

  if ! tar --extract --to-stdout --file "$tar_file" manifest.json >"$internal_manifest"; then
    log error "kind=verify backup_id=$BACKUP_ID message=manifest-missing"
    return 3
  fi
  if [[ $(metadata_value "$internal_manifest" '.backup_id // ""') != "$BACKUP_ID" \
    || $(metadata_value "$internal_manifest" '.payload_file // ""') != "$(basename -- "$BACKUP_PAYLOAD")" ]]; then
    log error "kind=verify backup_id=$BACKUP_ID message=manifest-mismatch"
    return 3
  fi
  if ! cmp --silent "$internal_manifest" "$BACKUP_METADATA"; then
    log error "kind=verify backup_id=$BACKUP_ID message=manifest-content-mismatch"
    return 3
  fi
}

verify_command() {
  require_command sha256sum
  require_command awk
  require_command cmp
  require_command find
  require_command flock
  require_command sort
  if ! acquire_lock; then
    return 3
  fi
  if ! select_backup "$BACKUP_REFERENCE"; then
    return 3
  fi
  if ! verify_checksum; then
    return 3
  fi
  if [[ $VERIFY_MODE == full ]]; then
    make_work_directory
    if ! prepare_tar; then
      cleanup_work_directory
      return 3
    fi
    cleanup_work_directory
  fi
  log info "event=verify-succeeded backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME mode=$VERIFY_MODE"
}

restore_command() {
  validate_absolute_path restore.to "$RESTORE_DIRECTORY"
  require_command sha256sum
  require_command awk
  require_command cmp
  require_command find
  require_command sort

  if [[ $DRY_RUN == true ]]; then
    if ! select_backup "$BACKUP_REFERENCE"; then
      return 3
    fi
    log info "event=plan-restore backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME to=$RESTORE_DIRECTORY"
    return 0
  fi

  require_command flock
  if ! acquire_lock; then
    return 3
  fi
  if ! select_backup "$BACKUP_REFERENCE"; then
    return 3
  fi
  if ! verify_checksum; then
    return 3
  fi
  make_work_directory
  if ! prepare_tar; then
    cleanup_work_directory
    return 3
  fi

  local target_created=false
  if [[ -e $RESTORE_DIRECTORY ]]; then
    [[ -d $RESTORE_DIRECTORY ]] || config_error "restore-target-not-directory"
    if [[ -n $(find "$RESTORE_DIRECTORY" -mindepth 1 -maxdepth 1 -print -quit) ]]; then
      config_error "restore-target-must-be-empty path=$RESTORE_DIRECTORY"
    fi
  else
    local parent
    parent=$(dirname -- "$RESTORE_DIRECTORY")
    [[ -d $parent && -w $parent ]] || config_error "restore-target-parent-not-writable path=$parent"
    mkdir -- "$RESTORE_DIRECTORY"
    target_created=true
  fi
  [[ $target_created == false ]] || chmod 0700 "$RESTORE_DIRECTORY"

  if ! tar --extract --file "$WORK_DIRECTORY/backup.tar" --directory "$RESTORE_DIRECTORY" \
    --strip-components=1 --no-same-owner --delay-directory-restore; then
    log error "event=restore-failed backup_id=$BACKUP_ID to=$RESTORE_DIRECTORY"
    cleanup_work_directory
    return 3
  fi
  cleanup_work_directory
  log info "event=restore-succeeded backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME to=$RESTORE_DIRECTORY"
}

declare -a PRUNE_RECORDS=()

collect_prune_records() {
  local destination_path=$1
  local job=$2
  local marker backup_id metadata metadata_job created payload
  local -a unsorted=()
  PRUNE_RECORDS=()

  while IFS= read -r -d '' marker; do
    backup_id=$(basename -- "$marker" .complete)
    validate_identifier backup_id "$backup_id"
    if ! validate_backup_bundle "$destination_path" "$backup_id"; then
      log error "kind=prune backup_id=$backup_id message=invalid-complete-bundle"
      return 3
    fi
    metadata="$destination_path/$backup_id.metadata.json"
    metadata_job=$(metadata_value "$metadata" '.job // ""')
    [[ $metadata_job == "$job" ]] || continue
    created=$(metadata_value "$metadata" '.created_at // ""')
    payload=$(metadata_value "$metadata" '.payload_file // ""')
    [[ $created =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 3
    unsorted+=("$created|$backup_id|$payload")
  done < <(iterate_destination_markers "$destination_path")

  if ((${#unsorted[@]} > 0)); then
    mapfile -t PRUNE_RECORDS < <(printf '%s\n' "${unsorted[@]}" | sort -r)
  fi
}

prune_job_destination() {
  local job_index=$1
  local destination_index=$2
  local job destination destination_path keep_last keep_daily keep_weekly keep_monthly
  local -a records=()
  local -A keep=() seen_daily=() seen_weekly=() seen_monthly=()
  local record created backup_id payload index bucket daily_count=0 weekly_count=0 monthly_count=0

  job=$(cfg ".jobs[$job_index].name")
  destination=$(cfg ".destinations[$destination_index].name")
  destination_path=$(cfg ".destinations[$destination_index].path")
  [[ -d $destination_path ]] || return 0
  keep_last=$(cfg ".jobs[$job_index].retention.keep_last // 3")
  keep_daily=$(cfg ".jobs[$job_index].retention.keep_daily // 0")
  keep_weekly=$(cfg ".jobs[$job_index].retention.keep_weekly // 0")
  keep_monthly=$(cfg ".jobs[$job_index].retention.keep_monthly // 0")

  if ! collect_prune_records "$destination_path" "$job"; then
    log error "kind=prune job=$job destination=$destination message=bundle-validation-failed"
    return 3
  fi
  records=("${PRUNE_RECORDS[@]}")
  ((${#records[@]} > 0)) || return 0

  for ((index = 0; index < ${#records[@]} && index < keep_last; index++)); do
    IFS='|' read -r created backup_id payload <<<"${records[$index]}"
    keep["$backup_id"]=1
  done

  for record in "${records[@]}"; do
    IFS='|' read -r created backup_id payload <<<"$record"
    if ((daily_count < keep_daily)); then
      if ! bucket=$(date -u -d "$created" +'%Y-%m-%d'); then
        return 3
      fi
      if [[ -z ${seen_daily[$bucket]+x} ]]; then
        seen_daily["$bucket"]=1
        keep["$backup_id"]=1
        daily_count=$((daily_count + 1))
      fi
    fi
    if ((weekly_count < keep_weekly)); then
      if ! bucket=$(date -u -d "$created" +'%G-W%V'); then
        return 3
      fi
      if [[ -z ${seen_weekly[$bucket]+x} ]]; then
        seen_weekly["$bucket"]=1
        keep["$backup_id"]=1
        weekly_count=$((weekly_count + 1))
      fi
    fi
    if ((monthly_count < keep_monthly)); then
      if ! bucket=$(date -u -d "$created" +'%Y-%m'); then
        return 3
      fi
      if [[ -z ${seen_monthly[$bucket]+x} ]]; then
        seen_monthly["$bucket"]=1
        keep["$backup_id"]=1
        monthly_count=$((monthly_count + 1))
      fi
    fi
  done

  for record in "${records[@]}"; do
    IFS='|' read -r created backup_id payload <<<"$record"
    [[ -z ${keep[$backup_id]+x} ]] || continue
    if [[ $DRY_RUN == true ]]; then
      log info "event=plan-prune job=$job destination=$destination backup_id=$backup_id"
      continue
    fi
    if rm -f -- "$destination_path/$payload" \
      "$destination_path/$backup_id.metadata.json" \
      "$destination_path/$backup_id.sha256" \
      "$destination_path/$backup_id.complete"; then
      log info "event=backup-pruned job=$job destination=$destination backup_id=$backup_id"
    else
      log error "kind=prune job=$job destination=$destination backup_id=$backup_id message=delete-failed"
      return 3
    fi
  done
}

prune_command() {
  require_command find
  require_command sort
  require_command date
  if [[ $DRY_RUN == false ]]; then
    require_command flock
    if ! acquire_lock; then
      return 3
    fi
  fi

  local job_index job destination_count destination_position destination_name destination_index result=0
  for ((job_index = 0; job_index < JOB_COUNT; job_index++)); do
    job=$(cfg ".jobs[$job_index].name")
    [[ -z $SELECTED_JOB || $job == "$SELECTED_JOB" ]] || continue
    destination_count=$(cfg ".jobs[$job_index].destinations | length")
    for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
      destination_name=$(cfg ".jobs[$job_index].destinations[$destination_position]")
      destination_index=$(find_destination_index "$destination_name")
      if ! prune_job_destination "$job_index" "$destination_index"; then
        result=3
      fi
    done
  done
  return "$result"
}

doctor_command() {
  preflight_selected_jobs
  local index name
  for ((index = 0; index < JOB_COUNT; index++)); do
    name=$(cfg ".jobs[$index].name")
    [[ -z $SELECTED_JOB || $name == "$SELECTED_JOB" ]] || continue
    log info "event=doctor-job-ok job=$name"
  done
  log info "event=doctor-succeeded version=$BACKFORT_VERSION"
}

parse_global_options() {
  while (($# > 0)); do
    case "$1" in
      -c)
        (($# >= 2)) || command_error "missing-value option=-c"
        CONFIG_FILE=$2
        shift 2
        ;;
      -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -V|--version)
        printf 'Backfort %s\n' "$BACKFORT_VERSION"
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      run|doctor|list|status|verify|restore|prune)
        COMMAND=$1
        shift
        REMAINING_ARGUMENTS=("$@")
        return 0
        ;;
      *)
        command_error "unknown-global-option value=$1"
        ;;
    esac
  done
  if [[ $DRY_RUN == true ]]; then
    COMMAND=run
    REMAINING_ARGUMENTS=()
  else
    command_error "missing-command"
  fi
}

parse_command_options() {
  set -- "${REMAINING_ARGUMENTS[@]}"
  case "$COMMAND" in
    run|doctor|status|prune)
      while (($# > 0)); do
        case "$1" in
          --job)
            (($# >= 2)) || command_error "missing-value option=--job"
            SELECTED_JOB=$2
            shift 2
            ;;
          -n|--dry-run)
            [[ $COMMAND == run || $COMMAND == prune ]] || command_error "dry-run-not-supported command=$COMMAND"
            DRY_RUN=true
            shift
            ;;
          *) command_error "unknown-option command=$COMMAND value=$1" ;;
        esac
      done
      ;;
    list)
      while (($# > 0)); do
        case "$1" in
          --job)
            (($# >= 2)) || command_error "missing-value option=--job"
            SELECTED_JOB=$2
            shift 2
            ;;
          --json)
            JSON_OUTPUT=true
            shift
            ;;
          *) command_error "unknown-option command=list value=$1" ;;
        esac
      done
      ;;
    verify|restore)
      (($# > 0)) || command_error "missing-backup-id command=$COMMAND"
      BACKUP_REFERENCE=$1
      shift
      while (($# > 0)); do
        case "$1" in
          --job)
            (($# >= 2)) || command_error "missing-value option=--job"
            SELECTED_JOB=$2
            shift 2
            ;;
          --from)
            (($# >= 2)) || command_error "missing-value option=--from"
            SELECTED_DESTINATION=$2
            shift 2
            ;;
          --quick)
            [[ $COMMAND == verify ]] || command_error "option-not-supported command=$COMMAND option=--quick"
            VERIFY_MODE=quick
            shift
            ;;
          --full)
            [[ $COMMAND == verify ]] || command_error "option-not-supported command=$COMMAND option=--full"
            VERIFY_MODE=full
            shift
            ;;
          --to)
            [[ $COMMAND == restore ]] || command_error "option-not-supported command=$COMMAND option=--to"
            (($# >= 2)) || command_error "missing-value option=--to"
            RESTORE_DIRECTORY=$2
            shift 2
            ;;
          -n|--dry-run)
            [[ $COMMAND == restore ]] || command_error "dry-run-not-supported command=$COMMAND"
            DRY_RUN=true
            shift
            ;;
          *) command_error "unknown-option command=$COMMAND value=$1" ;;
        esac
      done
      if [[ $COMMAND == restore && -z $RESTORE_DIRECTORY ]]; then
        command_error "restore-requires-to"
      fi
      ;;
  esac
}

main() {
  declare -ga REMAINING_ARGUMENTS=()
  parse_global_options "$@"
  parse_command_options

  validate_absolute_path config "$CONFIG_FILE"
  check_yq
  validate_config

  case "$COMMAND" in
    run) run_command ;;
    doctor) doctor_command ;;
    list) list_command ;;
    status) status_command ;;
    verify) verify_command ;;
    restore) restore_command ;;
    prune) prune_command ;;
  esac
}

main "$@"
