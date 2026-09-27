#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
LC_ALL=C
umask 077

readonly BACKFORT_VERSION="0.5.0-dev"

CONFIG_FILE="/etc/backfort/config.yaml"
CONFIG_FILE_EXPLICIT=false
DRY_RUN=false
COMMAND=""
SELECTED_JOB=""
SELECTED_DESTINATION=""
BACKUP_REFERENCE=""
VERIFY_MODE="quick"
RESTORE_DIRECTORY=""
RESTORE_PICK=false
RESTORE_PICK_CANCELLED=false
COMPOSE_RESTORE_PROJECT_DIRECTORY=""
COMPOSE_RESTORE_APPLY=false
COMPOSE_RESTORE_CONFIRMED=false
JSON_OUTPUT=false
WATCHDOG_MAX_AGE_HOURS=""
DIFF_ID_ONE=""
DIFF_ID_TWO=""
PIN_REASON=""
DELETE_PERIOD_SINCE=""
DELETE_PERIOD_UNTIL=""
DELETE_PERIOD_CONFIRMED=false
QUICK_NAME=""
QUICK_MIN_COPIES=1
QUICK_STATE_DIRECTORY=""
QUICK_FOLLOW_SYMLINKS=false
QUICK_COMPOSE_PROJECT_DIR=""
QUICK_COMPOSE_NAME=""
QUICK_COMPOSE_MIN_COPIES=1
QUICK_COMPOSE_VOLUME_HELPER_IMAGE=""
QUICK_COMPOSE_STATE_DIRECTORY=""
QUICK_CONFIG_DIRECTORY=""
QUICK_CONFIG_SAVED_PATH=""
declare -a QUICK_COMPOSE_FILES=()
declare -a QUICK_COMPOSE_DESTINATIONS=()
declare -a QUICK_COMPOSE_VOLUMES=()
declare -a QUICK_COMPOSE_BIND_MOUNTS=()
declare -a QUICK_COMPOSE_DATABASES=()
declare -a QUICK_PATHS=()
declare -a QUICK_DESTINATIONS=()
declare -a QUICK_EXCLUDES=()

NOTIFICATIONS_ENABLED=false
NOTIFY_DEFAULT_EVENTS=""
NOTIFY_ANTIFLOOD_HOURS=4
NOTIFY_DIGEST="off"
NOTIFY_CHANNEL_COUNT=0
NOTIFY_DEADLINE=0
declare -a NOTIFY_CHANNEL_NAMES=()
declare -a NOTIFY_CHANNEL_TYPES=()
declare -a NOTIFY_CHANNEL_EVENTS=()
declare -a NOTIFY_CHANNEL_TOKEN_ENVS=()
declare -a NOTIFY_CHANNEL_CHAT_ID_ENVS=()
declare -a NOTIFY_CHANNEL_THREAD_ID_ENVS=()
declare -a NOTIFY_CHANNEL_SERVERS=()
declare -a NOTIFY_CHANNEL_TOPIC_ENVS=()
declare -a NOTIFY_CHANNEL_PRIORITIES=()
declare -a NOTIFY_CHANNEL_URL_ENVS=()
declare -a NOTIFY_CHANNEL_HEADERS_ENVS=()
declare -a NOTIFY_CHANNEL_SMTP_TO=()
declare -a NOTIFY_CHANNEL_SMTP_FROM=()
declare -a NOTIFY_CHANNEL_SMTP_HOSTS=()
declare -a NOTIFY_CHANNEL_SMTP_PORTS=()
declare -a NOTIFY_CHANNEL_SMTP_STARTTLS=()
declare -a NOTIFY_CHANNEL_SMTP_USERNAME_ENVS=()
declare -a NOTIFY_CHANNEL_SMTP_PASSWORD_ENVS=()
declare -A NOTIFY_CHANNEL_TEMPLATES=()
declare -A NOTIFY_CHANNEL_TEMPLATE_SET=()
declare -a PRUNE_DELETED_IDS=()
PRUNE_FREED_BYTES=0

# Text-channel templates are deliberately kept in code rather than YAML so a
# minimally configured installation always emits an actionable alert.
readonly NOTIFY_TEMPLATE_FAILURE=$'[backfort] FAILURE job={{job}} host={{host}} error={{error}}\nRestore: {{restore_hint}}'
readonly NOTIFY_TEMPLATE_PARTIAL='[backfort] PARTIAL job={{job}} ok={{destinations}} failed={{failed_destinations}} id={{id}} size={{size}} — check destination health'
readonly NOTIFY_TEMPLATE_SUCCESS='[backfort] OK job={{job}} id={{id}} size={{size}} duration={{duration}}'
readonly NOTIFY_TEMPLATE_RECOVERY='[backfort] RECOVERED job={{job}} after failure — last good: {{id}} size={{size}}'
readonly NOTIFY_TEMPLATE_WATCHDOG=$'[backfort] WATCHDOG job={{job}} last_backup={{last_backup_age}} threshold={{threshold}}\nInvestigate or restore: {{restore_hint}}'
readonly NOTIFY_TEMPLATE_RESTORE_SUCCESS='[backfort] RESTORE OK job={{job}} id={{id}} target={{target}}'
readonly NOTIFY_TEMPLATE_RESTORE_FAILURE='[backfort] RESTORE FAILURE job={{job}} id={{id}} target={{target}} error={{error}}'
readonly NOTIFY_TEMPLATE_PRUNE='[backfort] PRUNE job={{job}} removed={{pinned_count}} freed={{freed}}'

HOST_ID=""
STATE_DIRECTORY=""
TEMP_DIRECTORY=""
LOCK_FILE=""
MIN_FREE_MB=0
PROMETHEUS_TEXTFILE_DIRECTORY=""
JOB_COUNT=0
DESTINATION_COUNT=0
WORK_DIRECTORY=""
LOCK_FD=""
POST_HOOK_PENDING=false
PRE_HOOK_RUNNING=false
POST_HOOK_JOB_INDEX=""
POST_HOOK_JOB_NAME=""
POST_HOOK_BACKUP_ID=""

# Hooks intentionally get a stable, system-only command search path. They can
# set a more specific PATH in their own root-owned script when needed.
readonly BACKFORT_HOOK_SAFE_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

usage() {
  cat <<EOF
Backfort ${BACKFORT_VERSION} - one-shot backup and recovery for Linux

Usage:
  backfort.sh [-c FILE] [-n] run [--job NAME]
  backfort.sh [-c FILE] doctor [--job NAME]
  backfort.sh [-c FILE] list [--job NAME] [--json]
  backfort.sh [-c FILE] status [--job NAME]
  backfort.sh [-c FILE] watchdog [--job NAME] [--max-age HOURS]
  backfort.sh [-c FILE] diff ID1 ID2 [--from DEST] [--json]
  backfort.sh [-c FILE] pin BACKUP_ID [--from DEST] [--reason TEXT]
  backfort.sh [-c FILE] unpin BACKUP_ID [--from DEST]
  backfort.sh [-c FILE] verify BACKUP_ID [--from DEST] [--quick|--full]
  backfort.sh [-c FILE] verify latest --job NAME [--from DEST] [--quick|--full]
  backfort.sh [-c FILE] restore BACKUP_ID --to DIRECTORY [--from DEST]
  backfort.sh [-c FILE] restore latest --job NAME --to DIRECTORY [--from DEST]
  backfort.sh [-c FILE] restore --pick --to DIRECTORY [--job NAME] [--from DEST]
  backfort.sh [-c FILE] restore-compose BACKUP_ID --to DIRECTORY [--from DEST] [--project-dir DIRECTORY --apply --confirm]
  backfort.sh [-c FILE] restore-compose latest --job NAME --to DIRECTORY [--from DEST] [--project-dir DIRECTORY --apply --confirm]
  backfort.sh [-c FILE] [-n] prune [--job NAME]
  backfort.sh [-c FILE] [-n] delete --job NAME --since YYYY-MM-DD --until YYYY-MM-DD [--from DEST] [--confirm]
  backfort.sh [-n] quick PATH [PATH ...] --to DESTINATION [OPTIONS]
  backfort.sh [-n] quick-compose PROJECT_DIR --to DESTINATION [OPTIONS]
  backfort.sh -V | --version

Exit codes:
  0  success
  1  at least one destination succeeded and at least one failed
  2  invalid arguments, configuration, dependencies, or environment
  3  operational failure or backup success policy not met
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
  local exit_status=$?

  # A hook may quiesce a filesystem or application before a backup starts.
  # Run its paired cleanup hook on every ordinary exit path, including a
  # handled signal and a completed failed pre-hook. Do not race a post hook
  # against a still-running pre hook interrupted by a signal. SIGKILL and a
  # host power loss cannot be intercepted, so hook scripts must make their
  # cleanup idempotent.
  if [[ ${POST_HOOK_PENDING:-false} == true ]]; then
    POST_HOOK_PENDING=false
    if [[ ${PRE_HOOK_RUNNING:-false} == true ]]; then
      log warning "kind=hook job=$POST_HOOK_JOB_NAME phase=post message=skipped-pre-hook-still-running"
    elif ! run_job_hook "$POST_HOOK_JOB_INDEX" "$POST_HOOK_JOB_NAME" "$POST_HOOK_BACKUP_ID" \
      post "$(hook_result_name "$exit_status")" "$exit_status"; then
      log error "kind=hook job=$POST_HOOK_JOB_NAME phase=post message=exit-cleanup-failed"
    fi
  fi

  cleanup_work_directory
  if [[ -n ${QUICK_CONFIG_DIRECTORY:-} ]]; then
    case "$QUICK_CONFIG_DIRECTORY" in
      /tmp/backfort.quick.*)
        rm -rf -- "$QUICK_CONFIG_DIRECTORY"
        ;;
      *)
        log error "kind=safety message=refusing-to-remove-unexpected-quick-config-directory"
        ;;
    esac
    QUICK_CONFIG_DIRECTORY=""
  fi
  return "$exit_status"
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

validate_gpg_fingerprint() {
  local kind=$1
  local value=$2
  if [[ ! $value =~ ^[A-Fa-f0-9]{40}$ && ! $value =~ ^[A-Fa-f0-9]{64}$ ]]; then
    config_error "invalid-gpg-fingerprint kind=$kind"
  fi
}

validate_integer() {
  local kind=$1
  local value=$2
  if [[ ! $value =~ ^[0-9]+$ ]]; then
    config_error "expected-non-negative-integer field=$kind value=$value"
  fi
}

normalize_watchdog_max_age() {
  local value=$1
  local leading_zeroes normalized

  [[ $value =~ ^[0-9]+$ ]] || return 1
  leading_zeroes=${value%%[!0]*}
  normalized=${value#"$leading_zeroes"}
  [[ -n $normalized ]] || normalized=0
  if (( ${#normalized} > 4 )) \
    || { (( ${#normalized} == 4 )) && (( 10#$normalized > 8760 )); } \
    || [[ $normalized == 0 ]]; then
    return 1
  fi
  printf '%s\n' "$normalized"
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

validate_rclone_path() {
  local kind=$1
  local value=$2
  if [[ -z $value || $value == /* || $value == *$'\n'* || $value == *$'\r'* \
    || $value == . || $value == .. || $value == ./* || $value == ../* \
    || $value == */../* || $value == */.. || $value == */./* || $value == */. ]]; then
    config_error "unsafe-rclone-path field=$kind"
  fi
}

validate_relative_path() {
  local kind=$1
  local value=$2
  if [[ -z $value || $value == /* || $value == *$'\n'* || $value == *$'\r'* \
    || $value == . || $value == .. || $value == ./* || $value == ../* \
    || $value == */../* || $value == */.. || $value == */./* || $value == */. ]]; then
    config_error "unsafe-relative-path field=$kind"
  fi
}

validate_docker_image_reference() {
  local kind=$1
  local value=$2
  if [[ ! $value =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]*$ || $value == *..* ]]; then
    config_error "unsafe-container-image field=$kind"
  fi
}

validate_container_path() {
  local kind=$1
  local value=$2
  validate_absolute_path "$kind" "$value"
  if [[ $value == *"'"* || $value == *';'* ]]; then
    config_error "unsafe-container-path field=$kind"
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

destination_type() {
  local index=$1
  cfg ".destinations[$index].type"
}

destination_local_path() {
  local index=$1
  cfg ".destinations[$index].path"
}

destination_rclone_root() {
  local index=$1
  local remote path
  remote=$(cfg ".destinations[$index].remote")
  path=$(cfg ".destinations[$index].path")
  printf '%s:%s\n' "$remote" "$path"
}

destination_object() {
  local index=$1
  local filename=$2
  local type root
  type=$(destination_type "$index")
  case "$type" in
    local)
      printf '%s/%s\n' "$(destination_local_path "$index")" "$filename"
      ;;
    rclone)
      root=$(destination_rclone_root "$index")
      printf '%s/%s\n' "$root" "$filename"
      ;;
    *)
      config_error "unsupported-destination-type index=$index type=$type"
      ;;
  esac
}

rclone_remote_configured() {
  local wanted=$1
  local remotes remote
  if ! remotes=$(rclone listremotes); then
    return 1
  fi
  while IFS= read -r remote; do
    [[ $remote == "$wanted:" ]] && return 0
  done <<<"$remotes"
  return 1
}

validate_files_source() {
  local job_index=$1
  local job_name=$2
  local source_path=".jobs[$job_index].source"
  local paths_count path_index path exclude_count exclude_index exclude follow_symlinks

  validate_keys "$source_path" 'type paths exclude follow_symlinks'
  [[ $(cfg "$source_path.paths | type") == '!!seq' ]] || config_error "source-paths-must-be-array job=$job_name"
  paths_count=$(cfg "$source_path.paths | length")
  validate_integer "jobs[$job_index].source.paths.length" "$paths_count"
  ((paths_count > 0)) || config_error "source-paths-empty job=$job_name"
  for ((path_index = 0; path_index < paths_count; path_index++)); do
    path=$(cfg "$source_path.paths[$path_index]")
    validate_absolute_path "jobs[$job_index].source.paths[$path_index]" "$path"
  done

  if [[ $(cfg "($source_path.exclude // []) | type") != '!!seq' ]]; then
    config_error "source-exclude-must-be-array job=$job_name"
  fi
  exclude_count=$(cfg "$source_path.exclude // [] | length")
  for ((exclude_index = 0; exclude_index < exclude_count; exclude_index++)); do
    exclude=$(cfg "$source_path.exclude[$exclude_index]")
    if [[ $exclude == *$'\n'* || $exclude == *$'\r'* ]]; then
      config_error "newline-in-exclude-pattern job=$job_name index=$exclude_index"
    fi
  done
  follow_symlinks=$(cfg "$source_path.follow_symlinks // false")
  validate_boolean "jobs[$job_index].source.follow_symlinks" "$follow_symlinks"
}

job_hook_configured() {
  local job_index=$1
  local phase=$2

  case "$phase" in
    pre|post) ;;
    *) return 1 ;;
  esac
  [[ $(cfg "(.jobs[$job_index].hooks // {}) | has(\"$phase\")") == true ]]
}

validate_job_hook() {
  local job_index=$1
  local job_name=$2
  local phase=$3
  local hook_path=".jobs[$job_index].hooks.$phase"
  local script argument_count argument_index argument

  [[ $(cfg "$hook_path | type") == '!!map' ]] \
    || config_error "hook-must-be-map job=$job_name phase=$phase"
  validate_keys "$hook_path" 'path args'
  [[ $(cfg "$hook_path.path | type") == '!!str' ]] \
    || config_error "hook-path-must-be-string job=$job_name phase=$phase"
  script=$(cfg "$hook_path.path // \"\"")
  validate_absolute_path "jobs[$job_index].hooks.$phase.path" "$script"

  [[ $(cfg "($hook_path.args // []) | type") == '!!seq' ]] \
    || config_error "hook-args-must-be-array job=$job_name phase=$phase"
  argument_count=$(cfg "($hook_path.args // []) | length")
  validate_integer "jobs[$job_index].hooks.$phase.args.length" "$argument_count"
  for ((argument_index = 0; argument_index < argument_count; argument_index++)); do
    [[ $(cfg "$hook_path.args[$argument_index] | type") == '!!str' ]] \
      || config_error "hook-argument-must-be-string job=$job_name phase=$phase index=$argument_index"
    argument=$(cfg "$hook_path.args[$argument_index]")
    if [[ $argument == *$'\n'* || $argument == *$'\r'* ]]; then
      config_error "newline-in-hook-argument job=$job_name phase=$phase index=$argument_index"
    fi
  done
}

validate_job_hooks() {
  local job_index=$1
  local job_name=$2
  local hooks_path=".jobs[$job_index].hooks"
  local phase

  [[ $(cfg "($hooks_path // {}) | type") == '!!map' ]] \
    || config_error "hooks-must-be-map job=$job_name"
  validate_keys "$hooks_path // {}" 'pre post'
  for phase in pre post; do
    job_hook_configured "$job_index" "$phase" || continue
    validate_job_hook "$job_index" "$job_name" "$phase"
  done
}

validate_hook_file() {
  local job_index=$1
  local job_name=$2
  local phase=$3
  local script=$4
  local owner mode

  [[ -f $script && -x $script && ! -L $script ]] \
    || config_error "hook-not-executable job=$job_name phase=$phase"
  owner=$(stat --format='%u' -- "$script") \
    || config_error "hook-stat-failed job=$job_name phase=$phase"
  [[ $owner == "$EUID" ]] \
    || config_error "hook-owner-mismatch job=$job_name phase=$phase"
  mode=$(stat --format='%a' -- "$script") \
    || config_error "hook-stat-failed job=$job_name phase=$phase"
  [[ $mode =~ ^[0-7]{3,4}$ ]] \
    || config_error "hook-invalid-mode job=$job_name phase=$phase"
  if (( (8#$mode & 8#22) != 0 )); then
    config_error "hook-group-or-other-writable job=$job_name phase=$phase"
  fi
  : "$job_index"
}

preflight_job_hooks() {
  local job_index=$1
  local job_name=$2
  local phase script

  for phase in pre post; do
    job_hook_configured "$job_index" "$phase" || continue
    script=$(cfg ".jobs[$job_index].hooks.$phase.path")
    validate_hook_file "$job_index" "$job_name" "$phase" "$script"
  done
}

job_signing_method() {
  local job_name=$1
  local job_index
  job_index=$(find_job_index "$job_name") || return 1
  cfg ".jobs[$job_index].signing.method // \"none\""
}

job_signing_public_key_env() {
  local job_name=$1
  local job_index
  job_index=$(find_job_index "$job_name") || return 1
  cfg ".jobs[$job_index].signing.public_key_env // \"\""
}

validate_compose_database_source() {
  local job_index=$1
  local job_name=$2
  local source_path=".jobs[$job_index].source"
  local database_count database_index database_path name other_name service engine user password_env
  local databases_count database_name database_position include_globals format backup_directory connect directory path

  [[ $(cfg "($source_path.databases // []) | type") == '!!seq' ]] \
    || config_error "compose-databases-must-be-array job=$job_name"
  database_count=$(cfg "$source_path.databases // [] | length")
  for ((database_index = 0; database_index < database_count; database_index++)); do
    database_path="$source_path.databases[$database_index]"
    [[ $(cfg "$database_path | type") == '!!map' ]] \
      || config_error "compose-database-must-be-map job=$job_name index=$database_index"
    name=$(cfg "$database_path.name // \"\"")
    service=$(cfg "$database_path.service // \"\"")
    engine=$(cfg "$database_path.engine // \"\"")
    user=$(cfg "$database_path.user // \"\"")
    password_env=$(cfg "$database_path.password_env // \"\"")
    validate_identifier "jobs[$job_index].source.databases[$database_index].name" "$name"
    validate_identifier "jobs[$job_index].source.databases[$database_index].service" "$service"
    validate_identifier "jobs[$job_index].source.databases[$database_index].user" "$user"
    validate_env_name "jobs[$job_index].source.databases[$database_index].password_env" "$password_env"

    for ((database_position = 0; database_position < database_index; database_position++)); do
      other_name=$(cfg "$source_path.databases[$database_position].name")
      [[ $name != "$other_name" ]] || config_error "duplicate-compose-database job=$job_name name=$name"
    done

    case "$engine" in
      postgres)
        validate_keys "$database_path" 'name service engine user password_env databases include_globals format'
        [[ $(cfg "$database_path.databases | type") == '!!seq' ]] \
          || config_error "compose-database-names-must-be-array job=$job_name name=$name"
        databases_count=$(cfg "$database_path.databases | length")
        ((databases_count > 0)) || config_error "compose-database-names-empty job=$job_name name=$name"
        include_globals=$(cfg "$database_path.include_globals // false")
        validate_boolean "jobs[$job_index].source.databases[$database_index].include_globals" "$include_globals"
        format=$(cfg "$database_path.format // \"custom\"")
        [[ $format == custom || $format == sql ]] \
          || config_error "unsupported-postgres-dump-format job=$job_name name=$name format=$format"
        ;;
      mysql|mariadb)
        validate_keys "$database_path" 'name service engine user password_env databases'
        [[ $(cfg "$database_path.databases | type") == '!!seq' ]] \
          || config_error "compose-database-names-must-be-array job=$job_name name=$name"
        databases_count=$(cfg "$database_path.databases | length")
        ((databases_count > 0)) || config_error "compose-database-names-empty job=$job_name name=$name"
        ;;
      mssql)
        validate_keys "$database_path" 'name service engine user password_env databases backup_directory'
        [[ $(cfg "$database_path.databases | type") == '!!seq' ]] \
          || config_error "compose-database-names-must-be-array job=$job_name name=$name"
        databases_count=$(cfg "$database_path.databases | length")
        ((databases_count > 0)) || config_error "compose-database-names-empty job=$job_name name=$name"
        backup_directory=$(cfg "$database_path.backup_directory // \"\"")
        validate_container_path "jobs[$job_index].source.databases[$database_index].backup_directory" "$backup_directory"
        ;;
      oracle)
        validate_keys "$database_path" 'name service engine user password_env connect directory path'
        connect=$(cfg "$database_path.connect // \"\"")
        directory=$(cfg "$database_path.directory // \"\"")
        path=$(cfg "$database_path.path // \"\"")
        validate_identifier "jobs[$job_index].source.databases[$database_index].connect" "$connect"
        validate_identifier "jobs[$job_index].source.databases[$database_index].directory" "$directory"
        validate_container_path "jobs[$job_index].source.databases[$database_index].path" "$path"
        ;;
      *) config_error "unsupported-compose-database-engine job=$job_name name=$name engine=$engine" ;;
    esac

    case "$engine" in
      postgres|mysql|mariadb|mssql)
        for ((database_position = 0; database_position < databases_count; database_position++)); do
          database_name=$(cfg "$database_path.databases[$database_position]")
          validate_identifier "jobs[$job_index].source.databases[$database_index].databases[$database_position]" "$database_name"
        done
        ;;
    esac
  done
}

validate_docker_compose_source() {
  local job_index=$1
  local job_name=$2
  local source_path=".jobs[$job_index].source"
  local project_dir files_count file_index file volumes_count volume_index volume other_volume helper_image
  local bind_count bind_index bind_path bind_name bind_source other_bind

  validate_keys "$source_path" 'type project_dir files volumes bind_mounts databases volume_helper_image'
  project_dir=$(cfg "$source_path.project_dir // \"\"")
  validate_absolute_path "jobs[$job_index].source.project_dir" "$project_dir"

  [[ $(cfg "$source_path.files | type") == '!!seq' ]] || config_error "compose-files-must-be-array job=$job_name"
  files_count=$(cfg "$source_path.files | length")
  ((files_count > 0)) || config_error "compose-files-empty job=$job_name"
  for ((file_index = 0; file_index < files_count; file_index++)); do
    file=$(cfg "$source_path.files[$file_index]")
    validate_relative_path "jobs[$job_index].source.files[$file_index]" "$file"
  done

  [[ $(cfg "($source_path.volumes // []) | type") == '!!seq' ]] \
    || config_error "compose-volumes-must-be-array job=$job_name"
  volumes_count=$(cfg "$source_path.volumes // [] | length")
  for ((volume_index = 0; volume_index < volumes_count; volume_index++)); do
    volume=$(cfg "$source_path.volumes[$volume_index]")
    validate_identifier "jobs[$job_index].source.volumes[$volume_index]" "$volume"
    for ((other_volume = 0; other_volume < volume_index; other_volume++)); do
      [[ $volume != "$(cfg "$source_path.volumes[$other_volume]")" ]] \
        || config_error "duplicate-compose-volume job=$job_name volume=$volume"
    done
  done
  if ((volumes_count > 0)); then
    helper_image=$(cfg "$source_path.volume_helper_image // \"\"")
    validate_docker_image_reference "jobs[$job_index].source.volume_helper_image" "$helper_image"
  fi

  [[ $(cfg "($source_path.bind_mounts // []) | type") == '!!seq' ]] \
    || config_error "compose-bind-mounts-must-be-array job=$job_name"
  bind_count=$(cfg "$source_path.bind_mounts // [] | length")
  for ((bind_index = 0; bind_index < bind_count; bind_index++)); do
    bind_path="$source_path.bind_mounts[$bind_index]"
    [[ $(cfg "$bind_path | type") == '!!map' ]] \
      || config_error "compose-bind-mount-must-be-map job=$job_name index=$bind_index"
    validate_keys "$bind_path" 'name path'
    bind_name=$(cfg "$bind_path.name // \"\"")
    bind_source=$(cfg "$bind_path.path // \"\"")
    validate_identifier "jobs[$job_index].source.bind_mounts[$bind_index].name" "$bind_name"
    validate_relative_path "jobs[$job_index].source.bind_mounts[$bind_index].path" "$bind_source"
    for ((other_bind = 0; other_bind < bind_index; other_bind++)); do
      [[ $bind_name != "$(cfg "$source_path.bind_mounts[$other_bind].name")" ]] \
        || config_error "duplicate-compose-bind-mount job=$job_name name=$bind_name"
    done
  done

  validate_compose_database_source "$job_index" "$job_name"
}

validate_notification_event() {
  local event=$1

  case "$event" in
    success|partial|failure|recovery|watchdog|restore_success|restore_failure|prune|drill_failure) : ;;
    *) config_error "unsupported-notification-event event=$event" ;;
  esac
}

validate_notification_events() {
  local expression=$1
  local field=$2
  local event count

  [[ $(cfg "$expression | type") == '!!seq' ]] \
    || config_error "notification-events-must-be-array field=$field"
  count=$(cfg "$expression | length")
  ((count > 0)) || config_error "notification-events-empty field=$field"
  while IFS= read -r event; do
    validate_notification_event "$event"
  done < <(cfg "$expression | .[]")
}

notification_template_placeholder_is_allowed() {
  local placeholder=$1

  case "$placeholder" in
    event|job|id|host|size|duration|exit_code|error|destinations|failed_destinations|target|last_backup_age|threshold|pinned_count|freed|restore_hint) return 0 ;;
    *) return 1 ;;
  esac
}

# Canonicalising whitespace around placeholders leaves the literal portions of
# a trusted root-owned template untouched and gives the renderer fixed tokens.
bf_template_canonicalize() {
  local template=$1
  local channel=$2
  local remaining=$template prefix token placeholder result=''

  while [[ $remaining == *'{{'* ]]; do
    prefix=${remaining%%'{{'*}
    remaining=${remaining#*'{{'}
    if [[ $remaining != *'}}'* ]]; then
      config_error "invalid-notification-template channel=$channel reason=unclosed-placeholder"
    fi
    token=${remaining%%'}}'*}
    remaining=${remaining#*'}}'}
    if [[ ! $token =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*$ ]]; then
      config_error "invalid-notification-template channel=$channel placeholder=${token:-empty}"
    fi
    placeholder=${BASH_REMATCH[1]}
    if ! notification_template_placeholder_is_allowed "$placeholder"; then
      config_error "unknown-notification-template-placeholder channel=$channel placeholder=$placeholder"
    fi
    result+="${prefix}{{${placeholder}}}"
  done
  if [[ $remaining == *'}}'* ]]; then
    config_error "invalid-notification-template channel=$channel reason=unmatched-close"
  fi
  printf '%s\n' "${result}${remaining}"
}

validate_notification_templates() {
  local channel_path=$1
  local channel_name=$2
  local event template

  [[ $(cfg "$channel_path | has(\"templates\")") == true ]] || return 0
  [[ $(cfg "$channel_path.templates | type") == '!!map' ]] \
    || config_error "notification-templates-must-be-map channel=$channel_name"
  while IFS= read -r event; do
    validate_notification_event "$event"
    [[ $(cfg "$channel_path.templates.$event | type") == '!!str' ]] \
      || config_error "notification-template-must-be-string channel=$channel_name event=$event"
    template=$(cfg "$channel_path.templates.$event")
    ((${#template} <= 1000)) \
      || config_error "notification-template-too-long channel=$channel_name event=$event max=1000"
    bf_template_canonicalize "$template" "$channel_name" >/dev/null
  done < <(cfg "$channel_path.templates | keys | .[]")
}

notification_url_is_safe() {
  local value=$1

  [[ $value =~ ^https?://[^[:space:]\"\\]+$ ]] \
    && [[ $value != *$'\n'* && $value != *$'\r'* ]]
}

validate_notification_url() {
  local field=$1
  local value=$2

  notification_url_is_safe "$value" || config_error "unsafe-notification-url field=$field"
}

validate_email_address() {
  local field=$1
  local value=$2

  if [[ ! $value =~ ^[^[:space:]@]+@[^[:space:]@]+$ || $value == *$'\n'* || $value == *$'\r'* ]]; then
    config_error "invalid-email-address field=$field"
  fi
}

validate_notifications_config() {
  local enabled channels_count channel_index channel_path channel_name channel_type
  local other_index other_name env_name server priority host port starttls recipient_count recipient_index recipient

  [[ $(cfg '.notifications | type') == '!!map' ]] || config_error "notifications-must-be-map"
  validate_keys '.notifications' 'enabled defaults channels'
  if [[ $(cfg '.notifications | has("enabled")') == true ]]; then
    [[ $(cfg '.notifications.enabled | type') == '!!bool' ]] \
      || config_error "notification-enabled-must-be-boolean"
  fi
  enabled=$(cfg '.notifications.enabled // false')
  validate_boolean notifications.enabled "$enabled"

  if [[ $(cfg '(.notifications.defaults // {}) | type') != '!!map' ]]; then
    config_error "notification-defaults-must-be-map"
  fi
  validate_keys '.notifications.defaults // {}' 'events antiflood_hours digest'
  if [[ $(cfg '(.notifications.defaults // {}) | has("events")') == true ]]; then
    validate_notification_events '.notifications.defaults.events' 'notifications.defaults.events'
  fi
  if [[ $(cfg '(.notifications.defaults // {}) | has("antiflood_hours")') == true ]]; then
    [[ $(cfg '.notifications.defaults.antiflood_hours | type') == '!!int' ]] \
      || config_error "notification-antiflood-hours-must-be-integer"
    validate_integer notifications.defaults.antiflood_hours "$(cfg '.notifications.defaults.antiflood_hours')"
    (($(cfg '.notifications.defaults.antiflood_hours') <= 8760)) \
      || config_error "notification-antiflood-hours-out-of-range max=8760"
  fi
  if [[ $(cfg '(.notifications.defaults // {}) | has("digest")') == true ]]; then
    case "$(cfg '.notifications.defaults.digest')" in
      off|daily) : ;;
      *) config_error "unsupported-notification-digest" ;;
    esac
  fi

  [[ $(cfg '(.notifications.channels // []) | type') == '!!seq' ]] \
    || config_error "notification-channels-must-be-array"
  channels_count=$(cfg '(.notifications.channels // []) | length')
  if [[ $enabled == true && $channels_count -eq 0 ]]; then
    config_error "notification-channels-required-when-enabled"
  fi

  for ((channel_index = 0; channel_index < channels_count; channel_index++)); do
    channel_path=".notifications.channels[$channel_index]"
    [[ $(cfg "$channel_path | type") == '!!map' ]] \
      || config_error "notification-channel-must-be-map index=$channel_index"
    channel_name=$(cfg "$channel_path.name // \"\"")
    channel_type=$(cfg "$channel_path.type // \"\"")
    validate_identifier "notifications.channels[$channel_index].name" "$channel_name"
    case "$channel_type" in
      telegram)
        validate_keys "$channel_path" 'name type token_env chat_id_env thread_id_env events templates'
        env_name=$(cfg "$channel_path.token_env // \"\"")
        validate_env_name "notifications.channels[$channel_index].token_env" "$env_name"
        env_name=$(cfg "$channel_path.chat_id_env // \"\"")
        validate_env_name "notifications.channels[$channel_index].chat_id_env" "$env_name"
        env_name=$(cfg "$channel_path.thread_id_env // \"\"")
        [[ -z $env_name ]] || validate_env_name "notifications.channels[$channel_index].thread_id_env" "$env_name"
        ;;
      ntfy)
        validate_keys "$channel_path" 'name type server topic_env priority events templates'
        server=$(cfg "$channel_path.server // \"\"")
        validate_notification_url "notifications.channels[$channel_index].server" "$server"
        env_name=$(cfg "$channel_path.topic_env // \"\"")
        validate_env_name "notifications.channels[$channel_index].topic_env" "$env_name"
        priority=$(cfg "$channel_path.priority // \"default\"")
        case "$priority" in
          min|low|default|high|max|urgent) : ;;
          *) config_error "unsupported-ntfy-priority channel=$channel_name" ;;
        esac
        ;;
      webhook)
        validate_keys "$channel_path" 'name type url_env headers_env events templates'
        env_name=$(cfg "$channel_path.url_env // \"\"")
        validate_env_name "notifications.channels[$channel_index].url_env" "$env_name"
        env_name=$(cfg "$channel_path.headers_env // \"\"")
        [[ -z $env_name ]] || validate_env_name "notifications.channels[$channel_index].headers_env" "$env_name"
        ;;
      smtp)
        validate_keys "$channel_path" 'name type host port starttls username_env password_env to from events templates'
        host=$(cfg "$channel_path.host // \"\"")
        [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
          || config_error "invalid-smtp-host channel=$channel_name"
        port=$(cfg "$channel_path.port // \"\"")
        validate_integer "notifications.channels[$channel_index].port" "$port"
        ((port > 0 && port <= 65535)) || config_error "smtp-port-out-of-range channel=$channel_name"
        [[ $(cfg "$channel_path.starttls | type") == '!!bool' ]] \
          || config_error "smtp-starttls-must-be-boolean channel=$channel_name"
        starttls=$(cfg "$channel_path.starttls // false")
        validate_boolean "notifications.channels[$channel_index].starttls" "$starttls"
        env_name=$(cfg "$channel_path.username_env // \"\"")
        validate_env_name "notifications.channels[$channel_index].username_env" "$env_name"
        env_name=$(cfg "$channel_path.password_env // \"\"")
        validate_env_name "notifications.channels[$channel_index].password_env" "$env_name"
        [[ $(cfg "$channel_path.to | type") == '!!seq' ]] \
          || config_error "smtp-recipients-must-be-array channel=$channel_name"
        recipient_count=$(cfg "$channel_path.to | length")
        ((recipient_count > 0)) || config_error "smtp-recipients-empty channel=$channel_name"
        for ((recipient_index = 0; recipient_index < recipient_count; recipient_index++)); do
          recipient=$(cfg "$channel_path.to[$recipient_index]")
          validate_email_address "notifications.channels[$channel_index].to[$recipient_index]" "$recipient"
        done
        validate_email_address "notifications.channels[$channel_index].from" "$(cfg "$channel_path.from // \"\"")"
        ;;
      *) config_error "unsupported-notification-channel-type channel=$channel_name type=$channel_type" ;;
    esac

    if [[ $(cfg "$channel_path | has(\"events\")") == true ]]; then
      validate_notification_events "$channel_path.events" "notifications.channels[$channel_index].events"
    fi
    validate_notification_templates "$channel_path" "$channel_name"
    for ((other_index = 0; other_index < channel_index; other_index++)); do
      other_name=$(cfg ".notifications.channels[$other_index].name")
      [[ $channel_name != "$other_name" ]] || config_error "duplicate-notification-channel name=$channel_name"
    done
  done
}

validate_metrics_config() {
  local directory

  [[ $(cfg '.metrics | type') == '!!map' ]] || config_error "metrics-must-be-map"
  validate_keys '.metrics' 'prometheus'
  [[ $(cfg '.metrics | has("prometheus")') == true ]] || return 0

  [[ $(cfg '.metrics.prometheus | type') == '!!map' ]] \
    || config_error "prometheus-metrics-must-be-map"
  validate_keys '.metrics.prometheus' 'textfile_directory'
  [[ $(cfg '.metrics.prometheus | has("textfile_directory")') == true ]] \
    || config_error "prometheus-textfile-directory-required"
  [[ $(cfg '.metrics.prometheus.textfile_directory | type') == '!!str' ]] \
    || config_error "prometheus-textfile-directory-must-be-string"

  directory=$(cfg '.metrics.prometheus.textfile_directory')
  validate_absolute_path metrics.prometheus.textfile_directory "$directory"
  PROMETHEUS_TEXTFILE_DIRECTORY=$directory
}

validate_config() {
  if [[ ! -f $CONFIG_FILE || ! -r $CONFIG_FILE ]]; then
    config_error "config-not-readable file=$CONFIG_FILE"
  fi

  if ! yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1; then
    config_error "invalid-yaml file=$CONFIG_FILE"
  fi

  validate_keys '.' 'version settings destinations jobs watchdog notifications metrics'

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

  PROMETHEUS_TEXTFILE_DIRECTORY=""
  if [[ $(cfg '. | has("metrics")') == true ]]; then
    validate_metrics_config
  fi

  DESTINATION_COUNT=$(cfg '.destinations | length')
  JOB_COUNT=$(cfg '.jobs | length')
  validate_integer destinations.length "$DESTINATION_COUNT"
  validate_integer jobs.length "$JOB_COUNT"
  ((DESTINATION_COUNT > 0)) || config_error "at-least-one-destination-required"
  ((JOB_COUNT > 0)) || config_error "at-least-one-job-required"

  local index other name type path remote other_name
  for ((index = 0; index < DESTINATION_COUNT; index++)); do
    name=$(cfg ".destinations[$index].name // \"\"")
    type=$(cfg ".destinations[$index].type // \"\"")
    validate_identifier destination "$name"
    case "$type" in
      local)
        validate_keys ".destinations[$index]" 'name type path'
        path=$(cfg ".destinations[$index].path // \"\"")
        validate_absolute_path "destinations[$index].path" "$path"
        ;;
      rclone)
        validate_keys ".destinations[$index]" 'name type remote path'
        remote=$(cfg ".destinations[$index].remote // \"\"")
        path=$(cfg ".destinations[$index].path // \"\"")
        validate_identifier "destinations[$index].remote" "$remote"
        validate_rclone_path "destinations[$index].path" "$path"
        ;;
      *)
        config_error "unsupported-destination-type destination=$name type=$type"
        ;;
    esac

    for ((other = 0; other < index; other++)); do
      other_name=$(cfg ".destinations[$other].name")
      [[ $name != "$other_name" ]] || config_error "duplicate-destination name=$name"
    done
  done

  local source_type destinations_count compression compression_level encryption signing
  local keep_last keep_daily keep_weekly keep_monthly min_keep max_age_days destination_name destination_index env_name minimum_copies
  local recipient_count recipient_index recipient_env password_env identity_password_env

  for ((index = 0; index < JOB_COUNT; index++)); do
    validate_keys ".jobs[$index]" 'name source destinations compression encryption signing retention success hooks'
    name=$(cfg ".jobs[$index].name // \"\"")
    validate_identifier job "$name"

    for ((other = 0; other < index; other++)); do
      other_name=$(cfg ".jobs[$other].name")
      [[ $name != "$other_name" ]] || config_error "duplicate-job name=$name"
    done

    [[ $(cfg ".jobs[$index].source | type") == '!!map' ]] || config_error "source-must-be-map job=$name"
    source_type=$(cfg ".jobs[$index].source.type // \"\"")
    case "$source_type" in
      files) validate_files_source "$index" "$name" ;;
      docker_compose) validate_docker_compose_source "$index" "$name" ;;
      *) config_error "unsupported-source-type job=$name type=$source_type" ;;
    esac
    validate_job_hooks "$index" "$name"

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

    if [[ $(cfg "(.jobs[$index].success // {}) | type") != '!!map' ]]; then
      config_error "success-must-be-map job=$name"
    fi
    validate_keys ".jobs[$index].success // {}" 'min_copies'
    minimum_copies=$(cfg ".jobs[$index].success.min_copies // 1")
    validate_integer "jobs[$index].success.min_copies" "$minimum_copies"
    ((minimum_copies > 0 && minimum_copies <= destinations_count)) \
      || config_error "min-copies-out-of-range job=$name"

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
    validate_keys ".jobs[$index].encryption // {}" 'method recipient_env recipients_env identity_file_env password_env identity_password_env'
    encryption=$(cfg ".jobs[$index].encryption.method // \"none\"")
    [[ $encryption == none || $encryption == age || $encryption == gpg ]] || config_error "unsupported-encryption job=$name method=$encryption"
    identity_password_env=$(cfg ".jobs[$index].encryption.identity_password_env // \"\"")
    if [[ $encryption != gpg && -n $identity_password_env ]]; then
      config_error "identity-password-requires-gpg-encryption job=$name"
    fi
    if [[ $encryption == age ]]; then
      env_name=$(cfg ".jobs[$index].encryption.recipient_env // \"\"")
      [[ $(cfg "(.jobs[$index].encryption.recipients_env // []) | type") == '!!seq' ]] \
        || config_error "age-recipients-must-be-array job=$name"
      recipient_count=$(cfg "(.jobs[$index].encryption.recipients_env // []) | length")
      if [[ -n $env_name && $recipient_count -gt 0 ]]; then
        config_error "age-recipient-and-recipients-are-mutually-exclusive job=$name"
      fi
      if [[ -n $env_name ]]; then
        validate_env_name "jobs[$index].encryption.recipient_env" "$env_name"
      else
        ((recipient_count > 0)) || config_error "age-recipient-required job=$name"
        for ((recipient_index = 0; recipient_index < recipient_count; recipient_index++)); do
          recipient_env=$(cfg ".jobs[$index].encryption.recipients_env[$recipient_index]")
          validate_env_name "jobs[$index].encryption.recipients_env[$recipient_index]" "$recipient_env"
        done
      fi
      env_name=$(cfg ".jobs[$index].encryption.identity_file_env // \"\"")
      if [[ -n $env_name ]]; then
        validate_env_name "jobs[$index].encryption.identity_file_env" "$env_name"
      fi
    elif [[ $encryption == gpg ]]; then
      password_env=$(cfg ".jobs[$index].encryption.password_env // \"\"")
      env_name=$(cfg ".jobs[$index].encryption.recipient_env // \"\"")
      [[ $(cfg "(.jobs[$index].encryption.recipients_env // []) | type") == '!!seq' ]] \
        || config_error "gpg-recipients-must-be-array job=$name"
      recipient_count=$(cfg "(.jobs[$index].encryption.recipients_env // []) | length")
      if [[ -n $password_env && ( -n $env_name || $recipient_count -gt 0 ) ]]; then
        config_error "gpg-password-and-recipients-are-mutually-exclusive job=$name"
      fi
      if [[ -n $env_name && $recipient_count -gt 0 ]]; then
        config_error "gpg-recipient-and-recipients-are-mutually-exclusive job=$name"
      fi
      if [[ -n $password_env ]]; then
        validate_env_name "jobs[$index].encryption.password_env" "$password_env"
        identity_password_env=$(cfg ".jobs[$index].encryption.identity_password_env // \"\"")
        [[ -z $identity_password_env ]] \
          || config_error "gpg-identity-password-requires-asymmetric-encryption job=$name"
      elif [[ -n $env_name ]]; then
        validate_env_name "jobs[$index].encryption.recipient_env" "$env_name"
      else
        ((recipient_count > 0)) || config_error "gpg-password-or-recipient-required job=$name"
        for ((recipient_index = 0; recipient_index < recipient_count; recipient_index++)); do
          recipient_env=$(cfg ".jobs[$index].encryption.recipients_env[$recipient_index]")
          validate_env_name "jobs[$index].encryption.recipients_env[$recipient_index]" "$recipient_env"
        done
      fi
      if [[ -z $password_env ]]; then
        identity_password_env=$(cfg ".jobs[$index].encryption.identity_password_env // \"\"")
        [[ -z $identity_password_env ]] \
          || validate_env_name "jobs[$index].encryption.identity_password_env" "$identity_password_env"
      fi
    fi

    if [[ $(cfg "(.jobs[$index].signing // {}) | type") != '!!map' ]]; then
      config_error "signing-must-be-map job=$name"
    fi
    validate_keys ".jobs[$index].signing // {}" 'method secret_key_env public_key_env'
    signing=$(cfg ".jobs[$index].signing.method // \"none\"")
    case "$signing" in
      none) : ;;
      minisign)
        env_name=$(cfg ".jobs[$index].signing.secret_key_env // \"\"")
        validate_env_name "jobs[$index].signing.secret_key_env" "$env_name"
        env_name=$(cfg ".jobs[$index].signing.public_key_env // \"\"")
        validate_env_name "jobs[$index].signing.public_key_env" "$env_name"
        ;;
      *) config_error "unsupported-signing job=$name method=$signing" ;;
    esac

    if [[ $(cfg "(.jobs[$index].retention // {}) | type") != '!!map' ]]; then
      config_error "retention-must-be-map job=$name"
    fi
    validate_keys ".jobs[$index].retention // {}" 'keep_last keep_daily keep_weekly keep_monthly min_keep max_age_days'
    keep_last=$(cfg ".jobs[$index].retention.keep_last // 3")
    keep_daily=$(cfg ".jobs[$index].retention.keep_daily // 0")
    keep_weekly=$(cfg ".jobs[$index].retention.keep_weekly // 0")
    keep_monthly=$(cfg ".jobs[$index].retention.keep_monthly // 0")
    min_keep=$(cfg ".jobs[$index].retention.min_keep // 1")
    max_age_days=$(cfg ".jobs[$index].retention.max_age_days // 0")
    validate_integer "jobs[$index].retention.keep_last" "$keep_last"
    validate_integer "jobs[$index].retention.keep_daily" "$keep_daily"
    validate_integer "jobs[$index].retention.keep_weekly" "$keep_weekly"
    validate_integer "jobs[$index].retention.keep_monthly" "$keep_monthly"
    validate_integer "jobs[$index].retention.min_keep" "$min_keep"
    validate_integer "jobs[$index].retention.max_age_days" "$max_age_days"
    ((keep_last > 0)) || config_error "keep-last-must-be-positive job=$name"
    ((min_keep > 0)) || config_error "min-keep-must-be-positive job=$name"
    if [[ $(cfg "(.jobs[$index].retention // {}) | has(\"max_age_days\")") == true ]] && ((max_age_days == 0)); then
      config_error "max-age-days-must-be-positive job=$name"
    fi
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

  if [[ $(cfg 'has("watchdog")') == true ]]; then
    validate_watchdog_config
  fi
  if [[ $(cfg 'has("notifications")') == true ]]; then
    validate_notifications_config
  fi
}

validate_watchdog_config() {
  local max_age job_count job_index job other_index other_job

  [[ $(cfg '.watchdog | type') == '!!map' ]] || config_error "watchdog-must-be-map"
  validate_keys '.watchdog' 'max_age_hours jobs'

  if [[ $(cfg '.watchdog | has("max_age_hours")') == true ]]; then
    [[ $(cfg '.watchdog.max_age_hours | type') == '!!int' ]] \
      || config_error "watchdog-max-age-must-be-integer"
    max_age=$(cfg '.watchdog.max_age_hours')
    validate_integer watchdog.max_age_hours "$max_age"
    if ! max_age=$(normalize_watchdog_max_age "$max_age"); then
      config_error "watchdog-max-age-out-of-range min=1 max=8760"
    fi
  fi

  if [[ $(cfg '.watchdog | has("jobs")') == true ]]; then
    [[ $(cfg '.watchdog.jobs | type') == '!!seq' ]] \
      || config_error "watchdog-jobs-must-be-array"
    job_count=$(cfg '.watchdog.jobs | length')
    ((job_count > 0)) || config_error "watchdog-jobs-empty"
    for ((job_index = 0; job_index < job_count; job_index++)); do
      job=$(cfg ".watchdog.jobs[$job_index]")
      validate_identifier "watchdog.jobs[$job_index]" "$job"
      find_job_index "$job" >/dev/null \
        || config_error "watchdog-unknown-job job=$job"
      for ((other_index = 0; other_index < job_index; other_index++)); do
        other_job=$(cfg ".watchdog.jobs[$other_index]")
        [[ $job != "$other_job" ]] \
          || config_error "duplicate-watchdog-job job=$job"
      done
    done
  fi
}

nearest_existing_directory() {
  local candidate=$1
  while [[ ! -d $candidate ]]; do
    if [[ -e $candidate || -L $candidate ]]; then
      return 1
    fi
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

docker_compose_job() {
  local job_index=$1
  shift
  local project_dir files_count file_index file
  local -a compose_arguments=(compose)

  project_dir=$(cfg ".jobs[$job_index].source.project_dir")
  compose_arguments+=(--project-directory "$project_dir")
  files_count=$(cfg ".jobs[$job_index].source.files | length")
  for ((file_index = 0; file_index < files_count; file_index++)); do
    file=$(cfg ".jobs[$job_index].source.files[$file_index]")
    compose_arguments+=(-f "$project_dir/$file")
  done
  docker "${compose_arguments[@]+"${compose_arguments[@]}"}" "$@"
}

docker_compose_target_project() {
  local job_index=$1
  local project_dir=$2
  shift 2
  local files_count file_index file
  local -a compose_arguments=(compose --project-directory "$project_dir")

  files_count=$(cfg ".jobs[$job_index].source.files | length")
  for ((file_index = 0; file_index < files_count; file_index++)); do
    file=$(cfg ".jobs[$job_index].source.files[$file_index]")
    compose_arguments+=(-f "$project_dir/$file")
  done
  docker "${compose_arguments[@]+"${compose_arguments[@]}"}" "$@"
}

compose_volume_name() {
  local job_index=$1
  local logical_name=$2
  local resolved_name

  if ! resolved_name=$(docker_compose_job "$job_index" config --format json \
    | BF_COMPOSE_VOLUME="$logical_name" yq eval -r '.volumes[strenv(BF_COMPOSE_VOLUME)].name // strenv(BF_COMPOSE_VOLUME)' -); then
    return 1
  fi
  validate_identifier compose_volume "$resolved_name"
  printf '%s\n' "$resolved_name"
}

preflight_files_source() {
  local index=$1
  local name=$2
  local destination_count=$3
  local paths_count path_index path canonical_source canonical_target
  local destination_position destination_name destination_index destination_type_value destination_path

  paths_count=$(cfg ".jobs[$index].source.paths | length")
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
        destination_type_value=$(destination_type "$destination_index")
        [[ $destination_type_value == local ]] || continue
        destination_path=$(destination_local_path "$destination_index")
        canonical_target=$(realpath -m -- "$destination_path")
        path_is_within "$canonical_target" "$canonical_source" && config_error "destination-inside-source job=$name destination=$destination_name"
      done
    fi
  done
  return 0
}

preflight_docker_compose_source() {
  local index=$1
  local name=$2
  local project_dir canonical_project files_count file_index file source_file canonical_file
  local bind_count bind_index bind_name bind_path bind_source canonical_bind
  local volume_count volume_index logical_volume docker_volume helper_image services database_count database_index service password_env

  require_command docker
  require_command grep
  project_dir=$(cfg ".jobs[$index].source.project_dir")
  [[ -d $project_dir && -r $project_dir ]] || config_error "compose-project-not-readable job=$name"
  canonical_project=$(realpath -e -- "$project_dir")

  files_count=$(cfg ".jobs[$index].source.files | length")
  for ((file_index = 0; file_index < files_count; file_index++)); do
    file=$(cfg ".jobs[$index].source.files[$file_index]")
    source_file="$project_dir/$file"
    [[ -f $source_file && ! -L $source_file && -r $source_file ]] \
      || config_error "compose-file-not-readable job=$name file=$file"
    canonical_file=$(realpath -e -- "$source_file")
    path_is_within "$canonical_file" "$canonical_project" \
      || config_error "compose-file-outside-project job=$name file=$file"
  done

  if ! docker_compose_job "$index" version >/dev/null \
    || ! docker_compose_job "$index" config --quiet >/dev/null; then
    config_error "compose-project-invalid-or-unavailable job=$name"
  fi
  services=$(docker_compose_job "$index" config --services) \
    || config_error "compose-services-unavailable job=$name"

  bind_count=$(cfg ".jobs[$index].source.bind_mounts // [] | length")
  for ((bind_index = 0; bind_index < bind_count; bind_index++)); do
    bind_name=$(cfg ".jobs[$index].source.bind_mounts[$bind_index].name")
    bind_path=$(cfg ".jobs[$index].source.bind_mounts[$bind_index].path")
    bind_source="$project_dir/$bind_path"
    [[ -e $bind_source || -L $bind_source ]] || config_error "compose-bind-mount-missing job=$name name=$bind_name"
    [[ -r $bind_source ]] || config_error "compose-bind-mount-not-readable job=$name name=$bind_name"
    canonical_bind=$(realpath -e -- "$bind_source")
    path_is_within "$canonical_bind" "$canonical_project" \
      || config_error "compose-bind-mount-outside-project job=$name name=$bind_name"
  done

  volume_count=$(cfg ".jobs[$index].source.volumes // [] | length")
  if ((volume_count > 0)); then
    helper_image=$(cfg ".jobs[$index].source.volume_helper_image")
    docker image inspect "$helper_image" >/dev/null 2>&1 \
      || config_error "compose-volume-helper-image-not-present job=$name image=$helper_image"
    for ((volume_index = 0; volume_index < volume_count; volume_index++)); do
      logical_volume=$(cfg ".jobs[$index].source.volumes[$volume_index]")
      docker_volume=$(compose_volume_name "$index" "$logical_volume") \
        || config_error "compose-volume-resolution-failed job=$name volume=$logical_volume"
      docker volume inspect "$docker_volume" >/dev/null 2>&1 \
        || config_error "compose-volume-not-present job=$name volume=$logical_volume"
    done
  fi

  database_count=$(cfg ".jobs[$index].source.databases // [] | length")
  for ((database_index = 0; database_index < database_count; database_index++)); do
    service=$(cfg ".jobs[$index].source.databases[$database_index].service")
    grep -Fx -- "$service" <<<"$services" >/dev/null \
      || config_error "compose-database-service-not-found job=$name service=$service"
    password_env=$(cfg ".jobs[$index].source.databases[$database_index].password_env")
    [[ -n ${!password_env-} ]] \
      || config_error "missing-environment-variable job=$name variable=$password_env"
  done
}

gpg_recipient_key_available() {
  local fingerprint=$1 listing

  listing=$(gpg --batch --no-tty --no-auto-key-retrieve --with-colons \
    --list-keys "$fingerprint" 2>/dev/null) || return 1
  awk -F: -v wanted="${fingerprint^^}" '
    $1 == "pub" { primary_fingerprint_next = 1; next }
    $1 == "fpr" {
      if (primary_fingerprint_next && toupper($10) == wanted) {
        found = 1
      }
      primary_fingerprint_next = 0
    }
    END { exit !found }
  ' <<<"$listing"
}

preflight_job() {
  local index=$1
  local check_destinations=${2:-true}
  local name compression encryption signing env_name env_value recipient_count recipient_index
  local source_type destination_count destination_name destination_position destination_index destination_type_value

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
  require_command cat
  require_command chmod
  require_command cp
  require_command dirname
  require_command env
  require_command flock
  require_command mkdir
  require_command mktemp
  require_command mv
  require_command rm
  require_command stat
  case "$compression" in
    gzip) require_command gzip ;;
    zstd) require_command zstd ;;
  esac
  case "$encryption" in
    age)
      require_command age
      env_name=$(cfg ".jobs[$index].encryption.recipient_env // \"\"")
      if [[ -n $env_name ]]; then
        env_value=${!env_name-}
        [[ -n $env_value ]] || config_error "missing-environment-variable job=$name variable=$env_name"
      else
        recipient_count=$(cfg ".jobs[$index].encryption.recipients_env // [] | length")
        for ((recipient_index = 0; recipient_index < recipient_count; recipient_index++)); do
          env_name=$(cfg ".jobs[$index].encryption.recipients_env[$recipient_index]")
          env_value=${!env_name-}
          [[ -n $env_value ]] || config_error "missing-environment-variable job=$name variable=$env_name"
        done
      fi
      ;;
    gpg)
      require_command gpg
      env_name=$(cfg ".jobs[$index].encryption.password_env // \"\"")
      if [[ -n $env_name ]]; then
        env_value=${!env_name-}
        [[ -n $env_value ]] || config_error "missing-environment-variable job=$name variable=$env_name"
      else
        env_name=$(cfg ".jobs[$index].encryption.recipient_env // \"\"")
        if [[ -n $env_name ]]; then
          env_value=${!env_name-}
          [[ -n $env_value ]] || config_error "missing-environment-variable job=$name variable=$env_name"
          validate_gpg_fingerprint "jobs[$index].encryption.recipient_env.value" "$env_value"
          gpg_recipient_key_available "$env_value" \
            || config_error "gpg-recipient-key-not-available job=$name variable=$env_name"
        else
          recipient_count=$(cfg ".jobs[$index].encryption.recipients_env // [] | length")
          for ((recipient_index = 0; recipient_index < recipient_count; recipient_index++)); do
            env_name=$(cfg ".jobs[$index].encryption.recipients_env[$recipient_index]")
            env_value=${!env_name-}
            [[ -n $env_value ]] || config_error "missing-environment-variable job=$name variable=$env_name"
            validate_gpg_fingerprint "jobs[$index].encryption.recipients_env[$recipient_index].value" "$env_value"
            gpg_recipient_key_available "$env_value" \
              || config_error "gpg-recipient-key-not-available job=$name variable=$env_name"
          done
        fi
      fi
      ;;
  esac
  signing=$(cfg ".jobs[$index].signing.method // \"none\"")
  if [[ $signing == minisign ]]; then
    require_command minisign
    env_name=$(cfg ".jobs[$index].signing.secret_key_env")
    env_value=${!env_name-}
    [[ -n $env_value ]] || config_error "missing-environment-variable job=$name variable=$env_name"
    validate_absolute_path "jobs[$index].signing.secret_key_env.value" "$env_value"
    [[ -f $env_value && -r $env_value && ! -L $env_value ]] \
      || config_error "minisign-secret-key-not-readable job=$name variable=$env_name"
    env_name=$(cfg ".jobs[$index].signing.public_key_env")
    env_value=${!env_name-}
    [[ -n $env_value ]] || config_error "missing-environment-variable job=$name variable=$env_name"
  fi

  destination_count=$(cfg ".jobs[$index].destinations | length")
  for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
    destination_name=$(cfg ".jobs[$index].destinations[$destination_position]")
    destination_index=$(find_destination_index "$destination_name")
    destination_type_value=$(destination_type "$destination_index")
    [[ $destination_type_value == local ]] || require_command rclone
  done
  source_type=$(cfg ".jobs[$index].source.type")
  case "$source_type" in
    files) preflight_files_source "$index" "$name" "$destination_count" ;;
    docker_compose) preflight_docker_compose_source "$index" "$name" ;;
    *) config_error "unsupported-source-type job=$name type=$source_type" ;;
  esac
  preflight_job_hooks "$index" "$name"

  local existing
  existing=$(nearest_existing_directory "$TEMP_DIRECTORY") || config_error "temp-directory-has-no-parent"
  [[ -w $existing ]] || config_error "temp-directory-parent-not-writable path=$existing"
  check_free_space "$TEMP_DIRECTORY" settings.temp_directory

  if [[ $check_destinations == true ]]; then
    for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
      destination_name=$(cfg ".jobs[$index].destinations[$destination_position]")
      local resolved_index
      resolved_index=$(find_destination_index "$destination_name")
      destination_type_value=$(destination_type "$resolved_index")
      case "$destination_type_value" in
        local)
          destination_path=$(destination_local_path "$resolved_index")
          existing=$(nearest_existing_directory "$destination_path") || config_error "destination-has-no-parent destination=$destination_name"
          [[ -w $existing ]] || config_error "destination-parent-not-writable destination=$destination_name path=$existing"
          check_free_space "$destination_path" "destination.$destination_name"
          ;;
        rclone)
          local remote
          remote=$(cfg ".destinations[$resolved_index].remote")
          if ! rclone_remote_configured "$remote"; then
            config_error "rclone-remote-not-configured destination=$destination_name remote=$remote"
          fi
          ;;
      esac
    done
  fi
}

preflight_selected_jobs() {
  local check_destinations=${1:-true}
  local index name
  for ((index = 0; index < JOB_COUNT; index++)); do
    name=$(cfg ".jobs[$index].name")
    [[ -z $SELECTED_JOB || $name == "$SELECTED_JOB" ]] || continue
    preflight_job "$index" "$check_destinations"
  done
}

preflight_prometheus_metrics() {
  [[ -n $PROMETHEUS_TEXTFILE_DIRECTORY ]] || return 0
  [[ -d $PROMETHEUS_TEXTFILE_DIRECTORY && ! -L $PROMETHEUS_TEXTFILE_DIRECTORY && -w $PROMETHEUS_TEXTFILE_DIRECTORY ]] \
    || config_error "prometheus-textfile-directory-not-usable path=$PROMETHEUS_TEXTFILE_DIRECTORY"
}

set_preflight_failure_event() {
  local job_name=$1
  local preflight_status=$2

  BACKFORT_EVENT_JOB=$job_name
  BACKFORT_EVENT_ID=''
  BACKFORT_EVENT_SIZE=''
  BACKFORT_EVENT_DURATION='0s'
  BACKFORT_EVENT_DESTINATIONS=''
  BACKFORT_EVENT_FAILED_DESTINATIONS=''
  BACKFORT_EVENT_STAGE='preflight'
  BACKFORT_EVENT_ERROR='job preflight failed; see Backfort log'
  BACKFORT_EVENT_EXTRA="preflight_exit_code=$preflight_status"
  BACKFORT_METRICS_SUCCESSFUL_COPIES=0
  BACKFORT_METRICS_FAILED_COPIES=0
}

ensure_runtime_directories() {
  mkdir -p -- "$STATE_DIRECTORY" "$TEMP_DIRECTORY" "$(dirname -- "$LOCK_FILE")"
  chmod 0700 "$STATE_DIRECTORY" "$TEMP_DIRECTORY"
}

bf_redact() {
  local value=${1:-}
  local redacted backup_id placeholder index
  local backup_id_pattern='[A-Za-z0-9._-]+_[A-Za-z0-9._-]+_[0-9]{8}T[0-9]{6}Z_[A-Fa-f0-9]{8}'
  local -a preserved_backup_ids=()

  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  # Backup IDs are public recovery references, not credentials. Preserve them
  # before the generic long-token rule so restore hints remain usable.
  while [[ $value =~ $backup_id_pattern ]]; do
    backup_id=${BASH_REMATCH[0]}
    index=${#preserved_backup_ids[@]}
    placeholder="BACKFORT_BACKUP_ID_${index}"
    preserved_backup_ids[index]=$backup_id
    value=${value/"$backup_id"/"$placeholder"}
  done
  if ! redacted=$(printf '%s' "$value" | sed -E \
    -e 's/([A-Za-z_][A-Za-z0-9_]*(KEY|TOKEN|PASSWORD|SECRET)[A-Za-z0-9_]*=)[^[:space:]]+/\1***/g' \
    -e 's/[A-Fa-f0-9]{24,}/***/g' \
    -e 's/[A-Za-z0-9+/_-]{32,}={0,2}/***/g'); then
    redacted='***'
  fi
  for ((index = 0; index < ${#preserved_backup_ids[@]}; index++)); do
    placeholder="BACKFORT_BACKUP_ID_${index}"
    redacted=${redacted//"$placeholder"/"${preserved_backup_ids[index]}"}
  done
  notification_utf8_prefix "$redacted" 300
}

notify_warning() {
  local channel=$1
  local reason=$2

  log warning "kind=notify channel=$channel message=$(bf_redact "$reason")"
}

notification_event_enabled() {
  local event=$1
  local events=$2
  local configured_event

  while IFS= read -r configured_event; do
    [[ $configured_event == "$event" ]] && return 0
  done <<<"$events"
  return 1
}

initialize_notifications() {
  local index path event template key

  NOTIFICATIONS_ENABLED=$(cfg '.notifications.enabled // false')
  NOTIFY_DEFAULT_EVENTS=''
  NOTIFY_ANTIFLOOD_HOURS=4
  NOTIFY_DIGEST=off
  NOTIFY_CHANNEL_COUNT=0
  NOTIFY_CHANNEL_NAMES=()
  NOTIFY_CHANNEL_TYPES=()
  NOTIFY_CHANNEL_EVENTS=()
  NOTIFY_CHANNEL_TOKEN_ENVS=()
  NOTIFY_CHANNEL_CHAT_ID_ENVS=()
  NOTIFY_CHANNEL_THREAD_ID_ENVS=()
  NOTIFY_CHANNEL_SERVERS=()
  NOTIFY_CHANNEL_TOPIC_ENVS=()
  NOTIFY_CHANNEL_PRIORITIES=()
  NOTIFY_CHANNEL_URL_ENVS=()
  NOTIFY_CHANNEL_HEADERS_ENVS=()
  NOTIFY_CHANNEL_SMTP_TO=()
  NOTIFY_CHANNEL_SMTP_FROM=()
  NOTIFY_CHANNEL_SMTP_HOSTS=()
  NOTIFY_CHANNEL_SMTP_PORTS=()
  NOTIFY_CHANNEL_SMTP_STARTTLS=()
  NOTIFY_CHANNEL_SMTP_USERNAME_ENVS=()
  NOTIFY_CHANNEL_SMTP_PASSWORD_ENVS=()
  NOTIFY_CHANNEL_TEMPLATES=()
  NOTIFY_CHANNEL_TEMPLATE_SET=()
  [[ $NOTIFICATIONS_ENABLED == true ]] || return 0

  if [[ $(cfg '(.notifications.defaults // {}) | has("events")') == true ]]; then
    while IFS= read -r event; do
      NOTIFY_DEFAULT_EVENTS+="$event"$'\n'
    done < <(cfg '.notifications.defaults.events | .[]')
  else
    NOTIFY_DEFAULT_EVENTS=$'failure\npartial\nrecovery\nwatchdog\n'
  fi
  if [[ $(cfg '(.notifications.defaults // {}) | has("antiflood_hours")') == true ]]; then
    NOTIFY_ANTIFLOOD_HOURS=$(cfg '.notifications.defaults.antiflood_hours')
  fi
  if [[ $(cfg '(.notifications.defaults // {}) | has("digest")') == true ]]; then
    NOTIFY_DIGEST=$(cfg '.notifications.defaults.digest')
  fi

  NOTIFY_CHANNEL_COUNT=$(cfg '(.notifications.channels // []) | length')
  for ((index = 0; index < NOTIFY_CHANNEL_COUNT; index++)); do
    path=".notifications.channels[$index]"
    NOTIFY_CHANNEL_NAMES[index]=$(cfg "$path.name")
    NOTIFY_CHANNEL_TYPES[index]=$(cfg "$path.type")
    if [[ $(cfg "$path | has(\"events\")") == true ]]; then
      NOTIFY_CHANNEL_EVENTS[index]=$(cfg "$path.events | .[]")
    else
      NOTIFY_CHANNEL_EVENTS[index]=$NOTIFY_DEFAULT_EVENTS
    fi
    NOTIFY_CHANNEL_TOKEN_ENVS[index]=$(cfg "$path.token_env // \"\"")
    NOTIFY_CHANNEL_CHAT_ID_ENVS[index]=$(cfg "$path.chat_id_env // \"\"")
    NOTIFY_CHANNEL_THREAD_ID_ENVS[index]=$(cfg "$path.thread_id_env // \"\"")
    NOTIFY_CHANNEL_SERVERS[index]=$(cfg "$path.server // \"\"")
    NOTIFY_CHANNEL_TOPIC_ENVS[index]=$(cfg "$path.topic_env // \"\"")
    NOTIFY_CHANNEL_PRIORITIES[index]=$(cfg "$path.priority // \"default\"")
    NOTIFY_CHANNEL_URL_ENVS[index]=$(cfg "$path.url_env // \"\"")
    NOTIFY_CHANNEL_HEADERS_ENVS[index]=$(cfg "$path.headers_env // \"\"")
    NOTIFY_CHANNEL_SMTP_TO[index]=$(cfg "($path.to // []) | join(\",\")")
    NOTIFY_CHANNEL_SMTP_FROM[index]=$(cfg "$path.from // \"\"")
    NOTIFY_CHANNEL_SMTP_HOSTS[index]=$(cfg "$path.host // \"\"")
    NOTIFY_CHANNEL_SMTP_PORTS[index]=$(cfg "$path.port // \"\"")
    NOTIFY_CHANNEL_SMTP_STARTTLS[index]=$(cfg "$path.starttls // false")
    NOTIFY_CHANNEL_SMTP_USERNAME_ENVS[index]=$(cfg "$path.username_env // \"\"")
    NOTIFY_CHANNEL_SMTP_PASSWORD_ENVS[index]=$(cfg "$path.password_env // \"\"")
    if [[ $(cfg "$path | has(\"templates\")") == true ]]; then
      while IFS= read -r event; do
        template=$(cfg "$path.templates.$event")
        key="$index:$event"
        NOTIFY_CHANNEL_TEMPLATES["$key"]=$(bf_template_canonicalize "$template" "${NOTIFY_CHANNEL_NAMES[index]}")
        NOTIFY_CHANNEL_TEMPLATE_SET["$key"]=true
      done < <(cfg "$path.templates | keys | .[]")
    fi
  done
}

notification_state_directory() {
  printf '%s/notify_state\n' "$STATE_DIRECTORY"
}

notification_state_file() {
  local job=$1
  printf '%s/%s.last_status\n' "$(notification_state_directory)" "$job"
}

notification_last_status() {
  local job=$1
  local file status stored_at

  file=$(notification_state_file "$job")
  [[ -f $file && ! -L $file ]] || return 1
  IFS=$'\t' read -r status stored_at <"$file" || return 1
  [[ $status == ok || $status == bad ]] || return 1
  [[ $stored_at =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s\n' "$status" "$stored_at"
}

notification_write_status() {
  local job=$1
  local status=$2
  local stored_at=$3
  local directory file temporary

  directory=$(notification_state_directory)
  file=$(notification_state_file "$job")
  if ! mkdir -p -- "$directory" || ! chmod 0700 "$directory"; then
    notify_warning state 'state-directory-unavailable'
    return 1
  fi
  if ! temporary=$(mktemp "$directory/.${job}.last_status.XXXXXXXX"); then
    notify_warning state 'state-file-create-failed'
    return 1
  fi
  if ! printf '%s\t%s\n' "$status" "$stored_at" >"$temporary" || ! chmod 0600 "$temporary" \
    || ! mv -f -- "$temporary" "$file"; then
    rm -f -- "$temporary"
    notify_warning state 'state-file-write-failed'
    return 1
  fi
  return 0
}

notification_antiflood_file() {
  local job=$1
  local channel=$2
  local event=$3
  printf '%s/%s.%s.%s.last_sent\n' "$(notification_state_directory)" "$job" "$channel" "$event"
}

notification_is_suppressed() {
  local event=$1
  local job=$2
  local channel=$3
  local file last_sent now_seconds period

  case "$event" in
    failure|partial|watchdog) : ;;
    *) return 1 ;;
  esac
  file=$(notification_antiflood_file "$job" "$channel" "$event")
  [[ -f $file && ! -L $file ]] || return 1
  IFS= read -r last_sent <"$file" || return 1
  [[ $last_sent =~ ^[0-9]+$ ]] || return 1
  now_seconds=$(date -u +%s)
  period=$((NOTIFY_ANTIFLOOD_HOURS * 3600))
  ((now_seconds - last_sent < period))
}

notification_mark_sent() {
  local event=$1
  local job=$2
  local channel=$3
  local directory file temporary now_seconds

  case "$event" in
    failure|partial|watchdog) : ;;
    *) return 0 ;;
  esac
  directory=$(notification_state_directory)
  file=$(notification_antiflood_file "$job" "$channel" "$event")
  now_seconds=$(date -u +%s)
  if ! mkdir -p -- "$directory" || ! chmod 0700 "$directory"; then
    notify_warning "$channel" 'antiflood-state-directory-unavailable'
    return 1
  fi
  if ! temporary=$(mktemp "$directory/.${job}.${channel}.${event}.XXXXXXXX"); then
    notify_warning "$channel" 'antiflood-state-create-failed'
    return 1
  fi
  if ! printf '%s\n' "$now_seconds" >"$temporary" || ! chmod 0600 "$temporary" \
    || ! mv -f -- "$temporary" "$file"; then
    rm -f -- "$temporary"
    notify_warning "$channel" 'antiflood-state-write-failed'
    return 1
  fi
  return 0
}

notification_message() {
  local event=$1
  local message error extra

  error=$(bf_redact "${BACKFORT_EVENT_ERROR:-}")
  extra=$(bf_redact "${BACKFORT_EVENT_EXTRA:-}")
  message="[backfort] $event host=$HOST_ID"
  [[ -z ${BACKFORT_EVENT_JOB:-} ]] || message+=" job=${BACKFORT_EVENT_JOB}"
  [[ -z ${BACKFORT_EVENT_ID:-} ]] || message+=" id=${BACKFORT_EVENT_ID}"
  [[ -z ${BACKFORT_EVENT_SIZE:-} ]] || message+=" size=${BACKFORT_EVENT_SIZE}"
  [[ -z ${BACKFORT_EVENT_DURATION:-} ]] || message+=" duration=${BACKFORT_EVENT_DURATION}"
  [[ -z ${BACKFORT_EVENT_DESTINATIONS:-} ]] || message+=" destinations=${BACKFORT_EVENT_DESTINATIONS}"
  [[ -z ${BACKFORT_EVENT_FAILED_DESTINATIONS:-} ]] || message+=" failed_destinations=${BACKFORT_EVENT_FAILED_DESTINATIONS}"
  [[ -z ${BACKFORT_EVENT_AGE:-} ]] || message+=" last_backup_age=${BACKFORT_EVENT_AGE}"
  [[ -z ${BACKFORT_EVENT_THRESHOLD:-} ]] || message+=" threshold=${BACKFORT_EVENT_THRESHOLD}"
  [[ -z ${BACKFORT_EVENT_STAGE:-} ]] || message+=" stage=${BACKFORT_EVENT_STAGE}"
  [[ -z ${BACKFORT_EVENT_TARGET:-} ]] || message+=" target=${BACKFORT_EVENT_TARGET}"
  [[ -z $error ]] || message+=" error=\"$error\""
  [[ -z $extra ]] || message+=" extra=\"$extra\""
  printf '%s\n' "$message"
}

notification_default_template() {
  local event=$1

  case "$event" in
    failure) printf '%s\n' "$NOTIFY_TEMPLATE_FAILURE" ;;
    partial) printf '%s\n' "$NOTIFY_TEMPLATE_PARTIAL" ;;
    success) printf '%s\n' "$NOTIFY_TEMPLATE_SUCCESS" ;;
    recovery) printf '%s\n' "$NOTIFY_TEMPLATE_RECOVERY" ;;
    watchdog) printf '%s\n' "$NOTIFY_TEMPLATE_WATCHDOG" ;;
    restore_success) printf '%s\n' "$NOTIFY_TEMPLATE_RESTORE_SUCCESS" ;;
    restore_failure) printf '%s\n' "$NOTIFY_TEMPLATE_RESTORE_FAILURE" ;;
    prune) printf '%s\n' "$NOTIFY_TEMPLATE_PRUNE" ;;
    *) printf '[backfort] {{event}} host={{host}}\n' ;;
  esac
}

notification_human_size() {
  local value=${1:-}

  value=${value%B}
  if [[ $value =~ ^[0-9]+$ ]]; then
    format_restore_pick_size "$value"
  else
    printf '%s\n' "$value"
  fi
}

notification_human_duration() {
  local value=${1:-}
  local seconds hours minutes remainder

  if [[ ! $value =~ ^[0-9]+s$ ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  seconds=${value%s}
  hours=$((seconds / 3600))
  minutes=$(((seconds % 3600) / 60))
  remainder=$((seconds % 60))
  if ((hours > 0)); then
    printf '%dh%dm%ds\n' "$hours" "$minutes" "$remainder"
  elif ((minutes > 0)); then
    printf '%dm%ds\n' "$minutes" "$remainder"
  else
    printf '%ds\n' "$remainder"
  fi
}

notification_restore_hint() {
  local job=${BACKFORT_EVENT_JOB:-}
  local backup_id=${BACKFORT_EVENT_ID:-}
  local restore_target config_quoted id_quoted target_quoted

  [[ -n $job && -n $backup_id ]] || return 0
  restore_target="/srv/restore-${job^^}"
  printf -v config_quoted '%q' "$CONFIG_FILE"
  printf -v id_quoted '%q' "$backup_id"
  printf -v target_quoted '%q' "$restore_target"
  printf 'sudo backfort.sh -c %s restore %s --to %s\n' \
    "$config_quoted" "$id_quoted" "$target_quoted"
}

notification_template_value() {
  local placeholder=$1
  local event=$2

  case "$placeholder" in
    event) printf '%s\n' "$event" ;;
    job) printf '%s\n' "${BACKFORT_EVENT_JOB:-}" ;;
    host) printf '%s\n' "$HOST_ID" ;;
    exit_code) printf '%s\n' "${BACKFORT_EVENT_EXIT_CODE:-}" ;;
    id)
      case "$event" in
        success|partial|failure|recovery|restore_success|restore_failure) printf '%s\n' "${BACKFORT_EVENT_ID:-}" ;;
        *) printf '\n' ;;
      esac
      ;;
    size)
      case "$event" in
        success|partial|recovery) notification_human_size "${BACKFORT_EVENT_SIZE:-}" ;;
        *) printf '\n' ;;
      esac
      ;;
    duration)
      case "$event" in
        success|partial|failure|recovery) notification_human_duration "${BACKFORT_EVENT_DURATION:-}" ;;
        *) printf '\n' ;;
      esac
      ;;
    error)
      case "$event" in
        failure|partial|restore_failure) printf '%s\n' "${BACKFORT_EVENT_ERROR:-}" ;;
        *) printf '\n' ;;
      esac
      ;;
    destinations)
      case "$event" in
        success|partial) printf '%s\n' "${BACKFORT_EVENT_DESTINATIONS:-}" ;;
        *) printf '\n' ;;
      esac
      ;;
    failed_destinations)
      case "$event" in
        partial) printf '%s\n' "${BACKFORT_EVENT_FAILED_DESTINATIONS:-}" ;;
        *) printf '\n' ;;
      esac
      ;;
    target)
      case "$event" in
        restore_success|restore_failure) printf '%s\n' "${BACKFORT_EVENT_TARGET:-}" ;;
        *) printf '\n' ;;
      esac
      ;;
    last_backup_age)
      [[ $event == watchdog ]] && printf '%s\n' "${BACKFORT_EVENT_AGE:-}" || printf '\n'
      ;;
    threshold)
      [[ $event == watchdog ]] && printf '%s\n' "${BACKFORT_EVENT_THRESHOLD:-}" || printf '\n'
      ;;
    pinned_count)
      [[ $event == prune ]] && printf '%s\n' "${#PRUNE_DELETED_IDS[@]}" || printf '\n'
      ;;
    freed)
      [[ $event == prune ]] && notification_human_size "$PRUNE_FREED_BYTES" || printf '\n'
      ;;
    restore_hint)
      case "$event" in
        success|partial|failure|recovery|watchdog) notification_restore_hint ;;
        *) printf '\n' ;;
      esac
      ;;
  esac
}

# LC_ALL=C is intentionally used globally by Backfort. This byte-aware helper
# reads complete UTF-8 sequences before cutting, so a notification never ends
# in the middle of a multibyte character even when locale data is unavailable.
notification_utf8_prefix() {
  local value=$1
  local maximum=$2
  local position=0 byte code width output=''

  while ((position < ${#value} && position < maximum)); do
    byte=${value:position:1}
    printf -v code '%d' "'$byte"
    width=1
    if ((code >= 194 && code <= 223)); then
      width=2
    elif ((code >= 224 && code <= 239)); then
      width=3
    elif ((code >= 240 && code <= 244)); then
      width=4
    fi
    ((position + width <= maximum)) || break
    output+=${value:position:width}
    position=$((position + width))
  done
  printf '%s\n' "$output"
}

notification_normalize_message() {
  local value=$1
  local channel_type=$2
  local maximum=8000 remaining line output='' truncated=false complete=false lines=0

  [[ $channel_type == telegram ]] && maximum=4096
  value=${value//$'\r'/}
  remaining=$value
  while [[ $complete == false ]]; do
    if [[ $remaining == *$'\n'* ]]; then
      line=${remaining%%$'\n'*}
      remaining=${remaining#*$'\n'}
    else
      line=$remaining
      complete=true
    fi
    if ((lines >= 20)); then
      truncated=true
      break
    fi
    if ((lines > 0)); then
      output+=$'\n'
    fi
    if ((${#line} > 400)); then
      line="$(notification_utf8_prefix "$line" 397)..."
      truncated=true
    fi
    output+=$line
    lines=$((lines + 1))
  done
  if ((${#output} > maximum)); then
    output="$(notification_utf8_prefix "$output" "$((maximum - 3))")..."
  elif [[ $truncated == true && $output != *... ]]; then
    if ((${#output} > maximum - 3)); then
      output=$(notification_utf8_prefix "$output" "$((maximum - 3))")
    fi
    output+='...'
  fi
  printf '%s\n' "$output"
}

# Templates are canonicalised and checked at config-validation time. The
# renderer only substitutes this fixed whitelist; template text is never code.
bf_template_render() {
  local template=$1
  local event=$2
  local channel_type=$3
  local placeholder value rendered=$template

  for placeholder in event job id host size duration exit_code error destinations failed_destinations target last_backup_age threshold pinned_count freed restore_hint; do
    value=$(notification_template_value "$placeholder" "$event")
    value=$(bf_redact "$value")
    if [[ $channel_type == telegram ]]; then
      value=$(notification_html_escape "$value")
    fi
    rendered=${rendered//"{{${placeholder}}}"/"$value"}
  done
  notification_normalize_message "$rendered" "$channel_type"
}

notification_render_channel_message() {
  local index=$1
  local event=$2
  local key="$index:$event"
  local template

  if [[ ${NOTIFY_CHANNEL_TEMPLATE_SET[$key]:-} == true ]]; then
    template=${NOTIFY_CHANNEL_TEMPLATES[$key]}
  else
    template=$(notification_default_template "$event")
  fi
  bf_template_render "$template" "$event" "${NOTIFY_CHANNEL_TYPES[index]}"
}

notification_event_json() {
  local event=$1
  local error extra

  error=$(bf_redact "${BACKFORT_EVENT_ERROR:-}")
  extra=$(bf_redact "${BACKFORT_EVENT_EXTRA:-}")
  BF_NOTIFY_EVENT="$event" \
  BF_NOTIFY_HOST="$HOST_ID" \
  BF_NOTIFY_JOB="${BACKFORT_EVENT_JOB:-}" \
  BF_NOTIFY_ID="${BACKFORT_EVENT_ID:-}" \
  BF_NOTIFY_SIZE="${BACKFORT_EVENT_SIZE:-}" \
  BF_NOTIFY_DURATION="${BACKFORT_EVENT_DURATION:-}" \
  BF_NOTIFY_DESTINATIONS="${BACKFORT_EVENT_DESTINATIONS:-}" \
  BF_NOTIFY_FAILED_DESTINATIONS="${BACKFORT_EVENT_FAILED_DESTINATIONS:-}" \
  BF_NOTIFY_AGE="${BACKFORT_EVENT_AGE:-}" \
  BF_NOTIFY_THRESHOLD="${BACKFORT_EVENT_THRESHOLD:-}" \
  BF_NOTIFY_STAGE="${BACKFORT_EVENT_STAGE:-}" \
  BF_NOTIFY_TARGET="${BACKFORT_EVENT_TARGET:-}" \
  BF_NOTIFY_ERROR="$error" \
  BF_NOTIFY_EXTRA="$extra" \
    yq eval -n -o=json '{
      "event": strenv(BF_NOTIFY_EVENT),
      "data": {
        "host": strenv(BF_NOTIFY_HOST), "job": strenv(BF_NOTIFY_JOB),
        "id": strenv(BF_NOTIFY_ID), "size": strenv(BF_NOTIFY_SIZE),
        "duration": strenv(BF_NOTIFY_DURATION),
        "destinations": strenv(BF_NOTIFY_DESTINATIONS),
        "failed_destinations": strenv(BF_NOTIFY_FAILED_DESTINATIONS),
        "last_backup_age": strenv(BF_NOTIFY_AGE), "threshold": strenv(BF_NOTIFY_THRESHOLD),
        "stage": strenv(BF_NOTIFY_STAGE), "target": strenv(BF_NOTIFY_TARGET),
        "error": strenv(BF_NOTIFY_ERROR), "extra": strenv(BF_NOTIFY_EXTRA)
      }
    }'
}

notification_make_body_file() {
  local body=$1

  if ! mkdir -p -- "$TEMP_DIRECTORY" || ! chmod 0700 "$TEMP_DIRECTORY"; then
    return 1
  fi
  if ! NOTIFY_BODY_FILE=$(mktemp "$TEMP_DIRECTORY/backfort.notify.body.XXXXXXXX"); then
    return 1
  fi
  if ! printf '%s' "$body" >"$NOTIFY_BODY_FILE" || ! chmod 0600 "$NOTIFY_BODY_FILE"; then
    rm -f -- "$NOTIFY_BODY_FILE"
    return 1
  fi
  return 0
}

notification_parse_headers() {
  local headers=${1:-}
  local header name backslash

  NOTIFY_CURL_HEADERS=''
  backslash=$(printf "\\\\")
  while IFS= read -r header; do
    [[ -z $header ]] && continue
    name=${header%%:*}
    if [[ $header != *:* || ! $name =~ ^[A-Za-z0-9-]+$ || $header == *$'\r'* || $header == *$'\n'* \
      || $header == *'"'* || $header == *"$backslash"* || $header =~ [[:cntrl:]] ]]; then
      return 1
    fi
    NOTIFY_CURL_HEADERS+="$header"$'\n'
  done <<<"$headers"
  return 0
}

notification_curl_post() {
  local url=$1
  local now_seconds timeout temporary header response

  command -v curl >/dev/null 2>&1 || return 4
  now_seconds=$(date -u +%s)
  ((now_seconds < NOTIFY_DEADLINE)) || return 3
  timeout=$((NOTIFY_DEADLINE - now_seconds))
  ((timeout > 10)) && timeout=10
  if ! temporary=$(mktemp "$TEMP_DIRECTORY/backfort.notify.curl.XXXXXXXX"); then
    return 1
  fi
  if ! { printf 'url = "%s"\n' "$url"; while IFS= read -r header; do
      [[ -z $header ]] || printf 'header = "%s"\n' "$header"
    done <<<"${NOTIFY_CURL_HEADERS:-}"; } >"$temporary" || ! chmod 0600 "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  if response=$(curl --silent --show-error --fail --max-time "$timeout" --config "$temporary" \
    --data-binary "@$NOTIFY_BODY_FILE" 2>&1); then
    rm -f -- "$temporary"
    NOTIFY_CURL_RESPONSE=$response
    return 0
  fi
  rm -f -- "$temporary"
  return 1
}

notification_html_escape() {
  local value=$1
  printf '%s' "$value" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

notification_send_telegram() {
  local index=$1
  local message=$2
  local channel token_env chat_env thread_env token chat thread body url

  channel=${NOTIFY_CHANNEL_NAMES[index]}
  token_env=${NOTIFY_CHANNEL_TOKEN_ENVS[index]}
  chat_env=${NOTIFY_CHANNEL_CHAT_ID_ENVS[index]}
  thread_env=${NOTIFY_CHANNEL_THREAD_ID_ENVS[index]}
  token=${!token_env-}
  chat=${!chat_env-}
  thread=''
  [[ -z $thread_env ]] || thread=${!thread_env-}
  if [[ -z $token || -z $chat ]]; then
    notify_warning "$channel" "skipped-missing-env token_env=$token_env chat_id_env=$chat_env"
    return 2
  fi
  if [[ ! $token =~ ^[0-9]+:[A-Za-z0-9_-]+$ || $chat == *$'\n'* || $chat == *$'\r'* \
    || $thread == *$'\n'* || $thread == *$'\r'* ]]; then
    notify_warning "$channel" 'skipped-invalid-telegram-env-value'
    return 2
  fi
  if ! body=$(BF_NOTIFY_CHAT="$chat" BF_NOTIFY_TEXT="$message" BF_NOTIFY_THREAD="$thread" \
    yq eval -n -o=json '{"chat_id": strenv(BF_NOTIFY_CHAT), "text": strenv(BF_NOTIFY_TEXT), "parse_mode": "HTML"} + ({"message_thread_id": strenv(BF_NOTIFY_THREAD)} | with_entries(select(.value != "")))'); then
    return 1
  fi
  notification_make_body_file "$body" || return 1
  NOTIFY_CURL_HEADERS='Content-Type: application/json'
  url="https://api.telegram.org/bot${token}/sendMessage"
  if notification_curl_post "$url"; then
    :
  else
    local result=$?
    rm -f -- "$NOTIFY_BODY_FILE"
    return "$result"
  fi
  rm -f -- "$NOTIFY_BODY_FILE"
  if [[ $NOTIFY_CURL_RESPONSE =~ \"ok\"[[:space:]]*:[[:space:]]*false ]]; then
    return 1
  fi
  return 0
}

notification_send_ntfy() {
  local index=$1
  local event=$2
  local message=$3
  local channel server topic_env topic priority url

  channel=${NOTIFY_CHANNEL_NAMES[index]}
  server=${NOTIFY_CHANNEL_SERVERS[index]%/}
  topic_env=${NOTIFY_CHANNEL_TOPIC_ENVS[index]}
  topic=${!topic_env-}
  priority=${NOTIFY_CHANNEL_PRIORITIES[index]}
  if [[ -z $topic ]]; then
    notify_warning "$channel" "skipped-missing-env topic_env=$topic_env"
    return 2
  fi
  if [[ ! $topic =~ ^[A-Za-z0-9._-]+$ ]]; then
    notify_warning "$channel" 'skipped-invalid-ntfy-topic'
    return 2
  fi
  if [[ $event != failure && $event != watchdog ]]; then
    priority=default
  fi
  notification_make_body_file "$message" || return 1
  NOTIFY_CURL_HEADERS=$'Content-Type: text/plain\nPriority: '
  NOTIFY_CURL_HEADERS+="$priority"
  url="$server/$topic"
  if notification_curl_post "$url"; then
    :
  else
    local result=$?
    rm -f -- "$NOTIFY_BODY_FILE"
    return "$result"
  fi
  rm -f -- "$NOTIFY_BODY_FILE"
  return 0
}

notification_send_webhook() {
  local index=$1
  local event=$2
  local channel url_env headers_env url headers parsed_headers body

  channel=${NOTIFY_CHANNEL_NAMES[index]}
  url_env=${NOTIFY_CHANNEL_URL_ENVS[index]}
  headers_env=${NOTIFY_CHANNEL_HEADERS_ENVS[index]}
  url=${!url_env-}
  headers=''
  [[ -z $headers_env ]] || headers=${!headers_env-}
  if [[ -z $url ]]; then
    notify_warning "$channel" "skipped-missing-env url_env=$url_env"
    return 2
  fi
  if ! notification_url_is_safe "$url"; then
    notify_warning "$channel" 'skipped-invalid-webhook-url'
    return 2
  fi
  if ! notification_parse_headers "$headers"; then
    notify_warning "$channel" 'skipped-invalid-webhook-headers'
    return 2
  fi
  parsed_headers=$NOTIFY_CURL_HEADERS
  if ! body=$(notification_event_json "$event"); then
    return 1
  fi
  notification_make_body_file "$body" || return 1
  NOTIFY_CURL_HEADERS=$'Content-Type: application/json\n'
  NOTIFY_CURL_HEADERS+="$parsed_headers"
  if notification_curl_post "$url"; then
    :
  else
    local result=$?
    rm -f -- "$NOTIFY_BODY_FILE"
    return "$result"
  fi
  rm -f -- "$NOTIFY_BODY_FILE"
  return 0
}

notification_send_smtp() {
  local index=$1
  local event=$2
  local message=$3
  local channel to from host port starttls username_env password_env username password configuration tls tls_starttls

  channel=${NOTIFY_CHANNEL_NAMES[index]}
  to=${NOTIFY_CHANNEL_SMTP_TO[index]}
  from=${NOTIFY_CHANNEL_SMTP_FROM[index]}
  host=${NOTIFY_CHANNEL_SMTP_HOSTS[index]}
  port=${NOTIFY_CHANNEL_SMTP_PORTS[index]}
  starttls=${NOTIFY_CHANNEL_SMTP_STARTTLS[index]}
  username_env=${NOTIFY_CHANNEL_SMTP_USERNAME_ENVS[index]}
  password_env=${NOTIFY_CHANNEL_SMTP_PASSWORD_ENVS[index]}
  username=${!username_env-}
  password=${!password_env-}
  if ! command -v msmtp >/dev/null 2>&1 && ! command -v sendmail >/dev/null 2>&1; then
    notify_warning "$channel" 'smtp-channel-skipped-no-sendmail-or-msmtp'
    return 2
  fi
  if [[ -z $username || -z $password ]]; then
    notify_warning "$channel" "skipped-missing-env username_env=$username_env password_env=$password_env"
    return 2
  fi
  if [[ $username == *$'\n'* || $username == *$'\r'* || $password == *$'\n'* || $password == *$'\r'* ]]; then
    notify_warning "$channel" 'skipped-invalid-smtp-env-value'
    return 2
  fi
  if command -v msmtp >/dev/null 2>&1; then
    if ! configuration=$(mktemp "$TEMP_DIRECTORY/backfort.notify.msmtp.XXXXXXXX"); then
      return 1
    fi
    if [[ $starttls == true ]]; then
      tls=on
      tls_starttls=on
    else
      tls=off
      tls_starttls=off
    fi
    if ! printf 'defaults\nauth on\nhost %s\nport %s\ntls %s\ntls_starttls %s\nuser %s\npassword %s\nfrom %s\n' \
      "$host" "$port" "$tls" "$tls_starttls" "$username" "$password" "$from" \
      >"$configuration" || ! chmod 0600 "$configuration"; then
      rm -f -- "$configuration"
      return 1
    fi
    if ! printf 'To: %s\nFrom: %s\nSubject: [backfort] %s\n\n%s\n' "$to" "$from" "$event" "$message" \
      | msmtp --file="$configuration" --read-recipients; then
      rm -f -- "$configuration"
      return 1
    fi
    rm -f -- "$configuration"
  elif ! printf 'To: %s\nFrom: %s\nSubject: [backfort] %s\n\n%s\n' "$to" "$from" "$event" "$message" \
    | sendmail -t; then
      return 1
  fi
  return 0
}

notification_send_channel() {
  local index=$1
  local event=$2
  local message=$3
  local type

  type=${NOTIFY_CHANNEL_TYPES[index]}
  case "$type" in
    telegram) notification_send_telegram "$index" "$message" ;;
    ntfy) notification_send_ntfy "$index" "$event" "$message" ;;
    webhook) notification_send_webhook "$index" "$event" ;;
    smtp) notification_send_smtp "$index" "$event" "$message" ;;
    *) return 1 ;;
  esac
}

notification_digest_directory() {
  printf '%s/notify_digest\n' "$STATE_DIRECTORY"
}

notification_record_digest() {
  local event=$1
  local message=$2
  local directory day file

  directory=$(notification_digest_directory)
  day=$(date -u +%F)
  file="$directory/$day.log"
  if ! mkdir -p -- "$directory" || ! chmod 0700 "$directory"; then
    notify_warning digest 'digest-directory-unavailable'
    return 1
  fi
  if ! printf '%s event=%s\n' "$message" "$event" >>"$file" || ! chmod 0600 "$file"; then
    notify_warning digest 'digest-write-failed'
    return 1
  fi
  return 0
}

notification_deliver_digest() {
  local day=$1
  local contents=$2
  local message channel channel_message index send_result delivered=false original_extra

  message="[backfort] daily digest host=$HOST_ID date=$day${contents:+ $contents}"
  original_extra=${BACKFORT_EVENT_EXTRA:-}
  BACKFORT_EVENT_EXTRA=$message
  for ((index = 0; index < NOTIFY_CHANNEL_COUNT; index++)); do
    channel=${NOTIFY_CHANNEL_NAMES[index]}
    if ! notification_event_enabled success "${NOTIFY_CHANNEL_EVENTS[index]}" \
      && ! notification_event_enabled prune "${NOTIFY_CHANNEL_EVENTS[index]}"; then
      continue
    fi
    channel_message=$message
    if [[ ${NOTIFY_CHANNEL_TYPES[index]} == telegram ]]; then
      channel_message=$(notification_html_escape "$channel_message")
    fi
    channel_message=$(notification_normalize_message "$channel_message" "${NOTIFY_CHANNEL_TYPES[index]}")
    if notification_send_channel "$index" success "$channel_message"; then
      send_result=0
    else
      send_result=$?
    fi
    case "$send_result" in
      0) delivered=true ;;
      2) : ;;
      3) notify_warning "$channel" 'digest-skipped-time-budget-exhausted' ;;
      4) notify_warning "$channel" 'missing-curl' ;;
      *) notify_warning "$channel" 'digest-delivery-failed' ;;
    esac
  done
  BACKFORT_EVENT_EXTRA=$original_extra
  [[ $delivered == true ]]
}

notification_flush_digests() {
  local directory today file day contents
  local -a files=()

  [[ $NOTIFY_DIGEST == daily ]] || return 0
  directory=$(notification_digest_directory)
  [[ -d $directory && ! -L $directory ]] || return 0
  today=$(date -u +%F)
  shopt -s nullglob
  files=("$directory"/*.log)
  shopt -u nullglob
  for file in "${files[@]+"${files[@]}"}"; do
    day=$(basename -- "$file" .log)
    [[ $day =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ && $day != "$today" ]] || continue
    contents=$(<"$file")
    if notification_deliver_digest "$day" "$contents"; then
      rm -f -- "$file"
    fi
  done
}

bf_notify() {
  local event=$1
  local message channel_message channel_job index channel send_result

  [[ $NOTIFICATIONS_ENABLED == true ]] || return 0
  validate_notification_event "$event"
  message=$(notification_message "$event")
  channel_job=${BACKFORT_EVENT_JOB:-global}
  NOTIFY_DEADLINE=$(( $(date -u +%s) + 20 ))
  notification_flush_digests || true
  if [[ $NOTIFY_DIGEST == daily && ( $event == success || $event == prune ) ]]; then
    # A daily digest is flushed on the first later Backfort event, so it does
    # not need a daemon and never delays a backup with a scheduled wake-up.
    notification_record_digest "$event" "$message" || true
    return 0
  fi
  for ((index = 0; index < NOTIFY_CHANNEL_COUNT; index++)); do
    channel=${NOTIFY_CHANNEL_NAMES[index]}
    notification_event_enabled "$event" "${NOTIFY_CHANNEL_EVENTS[index]}" || continue
    if notification_is_suppressed "$event" "$channel_job" "$channel"; then
      printf 'notify_suppressed event=%s channel=%s\n' "$event" "$channel" >&2
      continue
    fi
    if [[ ${NOTIFY_CHANNEL_TYPES[index]} == webhook ]]; then
      channel_message=''
    else
      channel_message=$(notification_render_channel_message "$index" "$event")
    fi
    if notification_send_channel "$index" "$event" "$channel_message"; then send_result=0; else send_result=$?; fi
    case "$send_result" in
      0) notification_mark_sent "$event" "$channel_job" "$channel" || true ;;
      2) : ;;
      3) notify_warning "$channel" 'delivery-skipped-time-budget-exhausted' ;;
      4) notify_warning "$channel" 'missing-curl' ;;
      *) notify_warning "$channel" 'delivery-failed' ;;
    esac
  done
  return 0
}

bf_notify_result() {
  local context=$1
  local result=$2
  local job=${BACKFORT_EVENT_JOB:-global}
  local now_seconds previous_record previous_status='' previous_seconds=0 incident_duration

  BACKFORT_EVENT_EXIT_CODE=$result
  [[ $NOTIFICATIONS_ENABLED == true ]] || return 0
  case "$context" in
    run)
      now_seconds=$(date -u +%s)
      if previous_record=$(notification_last_status "$job"); then
        IFS=$'\t' read -r previous_status previous_seconds <<<"$previous_record"
      fi
      case "$result" in
        0)
          notification_write_status "$job" ok "$now_seconds" || true
          if [[ $previous_status == bad ]]; then
            incident_duration=$((now_seconds - previous_seconds))
            ((incident_duration >= 0)) || incident_duration=0
            BACKFORT_EVENT_DURATION="${incident_duration}s"
            bf_notify recovery
          elif [[ -z $previous_status ]]; then
            bf_notify success
          fi
          ;;
        1)
          bf_notify partial
          notification_write_status "$job" bad "$now_seconds" || true
          ;;
        *)
          bf_notify failure
          notification_write_status "$job" bad "$now_seconds" || true
          ;;
      esac
      ;;
    restore)
      if ((result == 0)); then
        [[ ${RESTORE_PICK_CANCELLED:-false} == true ]] || bf_notify restore_success
      else
        bf_notify restore_failure
      fi
      ;;
    prune)
      ((${#PRUNE_DELETED_IDS[@]} == 0)) || bf_notify prune
      ;;
  esac
  return 0
}

doctor_notification_channels() {
  local index channel type reason status env_name value

  [[ $NOTIFICATIONS_ENABLED == true ]] || return 0
  for ((index = 0; index < NOTIFY_CHANNEL_COUNT; index++)); do
    channel=${NOTIFY_CHANNEL_NAMES[index]}
    type=${NOTIFY_CHANNEL_TYPES[index]}
    reason='ready'
    status=ok
    case "$type" in
      telegram)
        for env_name in "${NOTIFY_CHANNEL_TOKEN_ENVS[index]}" "${NOTIFY_CHANNEL_CHAT_ID_ENVS[index]}"; do
          value=${!env_name-}
          if [[ -z $value ]]; then
            status=warn
            reason="missing-env=$env_name"
            break
          fi
        done
        command -v curl >/dev/null 2>&1 || { status=warn; reason='missing-curl'; }
        ;;
      ntfy)
        env_name=${NOTIFY_CHANNEL_TOPIC_ENVS[index]}
        value=${!env_name-}
        if [[ -z $value ]]; then
          status=warn
          reason="missing-env=$env_name"
        elif ! command -v curl >/dev/null 2>&1; then
          status=warn
          reason='missing-curl'
        fi
        ;;
      webhook)
        env_name=${NOTIFY_CHANNEL_URL_ENVS[index]}
        value=${!env_name-}
        if [[ -z $value ]]; then
          status=warn
          reason="missing-env=$env_name"
        elif ! notification_url_is_safe "$value"; then
          status=warn
          reason='invalid-url-env-value'
        elif ! command -v curl >/dev/null 2>&1; then
          status=warn
          reason='missing-curl'
        fi
        ;;
      smtp)
        for env_name in "${NOTIFY_CHANNEL_SMTP_USERNAME_ENVS[index]}" "${NOTIFY_CHANNEL_SMTP_PASSWORD_ENVS[index]}"; do
          value=${!env_name-}
          if [[ -z $value ]]; then
            status=warn
            reason="missing-env=$env_name"
            break
          fi
        done
        if [[ $status == ok ]] && ! command -v sendmail >/dev/null 2>&1 \
          && ! command -v msmtp >/dev/null 2>&1; then
          status=warn
          reason='smtp-channel-skipped-no-sendmail-or-msmtp'
        fi
        ;;
    esac
    printf 'channel=%s type=%s status=%s reason=%s\n' "$channel" "$type" "$status" "$reason"
  done
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
  if ! WORK_DIRECTORY=$(mktemp -d "$TEMP_DIRECTORY/backfort.XXXXXXXX"); then
    WORK_DIRECTORY=""
    log error "kind=workspace message=create-failed"
    return 1
  fi
}

new_backup_id() {
  local job=$1
  local created_compact random_part
  created_compact=$(date -u +'%Y%m%dT%H%M%SZ')
  random_part=$(printf '%08x' "$(( (10#$(date -u +%s) ^ $$ ^ RANDOM ^ (RANDOM << 8)) & 0xffffffff ))")
  printf '%s_%s_%s_%s\n' "$HOST_ID" "$job" "$created_compact" "$random_part"
}

# Automatic discovery is deliberately scoped to this configured host. A shared
# bucket may contain healthy copies made by several servers with the same job
# name; those copies are neither candidates nor errors for this host.
backup_id_belongs_to_current_host() {
  [[ $1 == "$HOST_ID"_* ]]
}

backup_id_belongs_to_current_host_job() {
  local backup_id=$1
  local job=$2
  [[ $backup_id == "$HOST_ID"_"$job"_* ]]
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
  local entries_file=$5
  local output=$6

  BF_MANIFEST_VERSION=$BACKFORT_VERSION \
  BF_MANIFEST_ID=$backup_id \
  BF_MANIFEST_HOST=$HOST_ID \
  BF_MANIFEST_CREATED=$created_at \
  BF_MANIFEST_PAYLOAD=$payload_name \
  BF_MANIFEST_ENTRIES=$entries_file \
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
      \"success\": (.success // {\"min_copies\": 1}),
      \"compression\": (.compression // {\"method\": \"gzip\", \"level\": 6}),
      \"encryption\": (.encryption // {\"method\": \"none\"}),
      \"signing\": (.signing // {\"method\": \"none\"}),
      \"file_hash_algorithm\": \"sha256\",
      \"entries\": load(strenv(BF_MANIFEST_ENTRIES))
    }" "$CONFIG_FILE" >"$output"
}

compose_exec_with_secret() {
  local job_index=$1
  local database_index=$2
  local container_variable=$3
  local service=$4
  shift 4
  local password_env secret result

  password_env=$(cfg ".jobs[$job_index].source.databases[$database_index].password_env")
  secret=${!password_env-}
  [[ -n $secret ]] || config_error "missing-environment-variable job=$(cfg ".jobs[$job_index].name") variable=$password_env"

  if (
    export "$container_variable=$secret"
    docker_compose_job "$job_index" exec -T -e "$container_variable" "$service" "$@"
  ); then
    result=0
  else
    result=$?
  fi
  secret=""
  return "$result"
}

compose_target_exec_with_secret() {
  local job_index=$1
  local database_index=$2
  local project_dir=$3
  local container_variable=$4
  local service=$5
  shift 5
  local password_env secret result

  password_env=$(cfg ".jobs[$job_index].source.databases[$database_index].password_env")
  secret=${!password_env-}
  [[ -n $secret ]] || config_error "missing-environment-variable job=$(cfg ".jobs[$job_index].name") variable=$password_env"

  if (
    export "$container_variable=$secret"
    docker_compose_target_project "$job_index" "$project_dir" exec -T -e "$container_variable" "$service" "$@"
  ); then
    result=0
  else
    result=$?
  fi
  secret=""
  return "$result"
}

compose_container_id() {
  local job_index=$1
  local service=$2
  local container_id
  container_id=$(docker_compose_job "$job_index" ps -q "$service") || return 1
  validate_identifier compose_container "$container_id"
  printf '%s\n' "$container_id"
}

cleanup_compose_container_files() {
  local job_index=$1
  local service=$2
  shift 2
  if ! docker_compose_job "$job_index" exec -T "$service" rm -f -- "$@" >/dev/null 2>&1; then
    log warning "kind=compose-cleanup job=$(cfg ".jobs[$job_index].name") service=$service message=temporary-dump-cleanup-failed"
  fi
}

snapshot_postgres_database() {
  local job_index=$1
  local database_index=$2
  local snapshot_directory=$3
  local service user database_count database_position database_name output include_globals format extension
  local -a dump_arguments=()

  service=$(cfg ".jobs[$job_index].source.databases[$database_index].service")
  user=$(cfg ".jobs[$job_index].source.databases[$database_index].user")
  format=$(cfg ".jobs[$job_index].source.databases[$database_index].format // \"custom\"")
  case "$format" in
    custom)
      extension=dump
      dump_arguments=(--format=custom)
      ;;
    sql)
      extension=sql
      dump_arguments=(--format=plain)
      ;;
    *)
      log error "kind=compose-dump engine=postgres service=$service message=unsupported-format"
      return 2
      ;;
  esac
  database_count=$(cfg ".jobs[$job_index].source.databases[$database_index].databases | length")
  for ((database_position = 0; database_position < database_count; database_position++)); do
    database_name=$(cfg ".jobs[$job_index].source.databases[$database_index].databases[$database_position]")
    output="$snapshot_directory/$database_name.$extension"
    if ! compose_exec_with_secret "$job_index" "$database_index" PGPASSWORD "$service" \
      pg_dump "${dump_arguments[@]+"${dump_arguments[@]}"}" --no-owner --no-privileges --username "$user" --dbname "$database_name" >"$output"; then
      rm -f -- "$output"
      log error "kind=compose-dump engine=postgres service=$service database=$database_name message=dump-failed"
      return 3
    fi
  done

  include_globals=$(cfg ".jobs[$job_index].source.databases[$database_index].include_globals // false")
  if [[ $include_globals == true ]]; then
    output="$snapshot_directory/globals.sql"
    if ! compose_exec_with_secret "$job_index" "$database_index" PGPASSWORD "$service" \
      pg_dumpall --globals-only --username "$user" >"$output"; then
      rm -f -- "$output"
      log error "kind=compose-dump engine=postgres service=$service message=globals-dump-failed"
      return 3
    fi
  fi
}

snapshot_mysql_database() {
  local job_index=$1
  local database_index=$2
  local snapshot_directory=$3
  local service engine user dump_command database_count database_position database_name output

  service=$(cfg ".jobs[$job_index].source.databases[$database_index].service")
  engine=$(cfg ".jobs[$job_index].source.databases[$database_index].engine")
  user=$(cfg ".jobs[$job_index].source.databases[$database_index].user")
  [[ $engine == mysql ]] && dump_command=mysqldump || dump_command=mariadb-dump
  database_count=$(cfg ".jobs[$job_index].source.databases[$database_index].databases | length")
  for ((database_position = 0; database_position < database_count; database_position++)); do
    database_name=$(cfg ".jobs[$job_index].source.databases[$database_index].databases[$database_position]")
    output="$snapshot_directory/$database_name.sql"
    if ! compose_exec_with_secret "$job_index" "$database_index" MYSQL_PWD "$service" \
      "$dump_command" --single-transaction --routines --events --triggers --no-tablespaces \
      --user="$user" --databases "$database_name" >"$output"; then
      rm -f -- "$output"
      log error "kind=compose-dump engine=$engine service=$service database=$database_name message=dump-failed"
      return 3
    fi
  done
}

snapshot_mssql_database() {
  local job_index=$1
  local database_index=$2
  local snapshot_directory=$3
  local backup_id=$4
  local service user backup_directory database_count database_position database_name filename container_path query
  local container_id output

  service=$(cfg ".jobs[$job_index].source.databases[$database_index].service")
  user=$(cfg ".jobs[$job_index].source.databases[$database_index].user")
  backup_directory=$(cfg ".jobs[$job_index].source.databases[$database_index].backup_directory")
  database_count=$(cfg ".jobs[$job_index].source.databases[$database_index].databases | length")
  for ((database_position = 0; database_position < database_count; database_position++)); do
    database_name=$(cfg ".jobs[$job_index].source.databases[$database_index].databases[$database_position]")
    filename="backfort_${backup_id}_${database_name}.bak"
    container_path="${backup_directory%/}/$filename"
    query="BACKUP DATABASE [$database_name] TO DISK = N'$container_path' WITH COPY_ONLY, CHECKSUM, INIT, STATS = 10"
    if ! compose_exec_with_secret "$job_index" "$database_index" SQLCMDPASSWORD "$service" \
      sqlcmd -C -b -S localhost -U "$user" -Q "$query" >/dev/null; then
      cleanup_compose_container_files "$job_index" "$service" "$container_path"
      log error "kind=compose-dump engine=mssql service=$service database=$database_name message=backup-failed"
      return 3
    fi
    container_id=$(compose_container_id "$job_index" "$service") || {
      cleanup_compose_container_files "$job_index" "$service" "$container_path"
      log error "kind=compose-dump engine=mssql service=$service database=$database_name message=container-not-found"
      return 3
    }
    output="$snapshot_directory/$database_name.bak"
    if ! docker cp "$container_id:$container_path" "$output"; then
      rm -f -- "$output"
      cleanup_compose_container_files "$job_index" "$service" "$container_path"
      log error "kind=compose-dump engine=mssql service=$service database=$database_name message=copy-failed"
      return 3
    fi
    cleanup_compose_container_files "$job_index" "$service" "$container_path"
  done
}

snapshot_oracle_database() {
  local job_index=$1
  local database_index=$2
  local snapshot_directory=$3
  local backup_id=$4
  local service user connect directory path dumpfile logfile container_dump container_log container_id output

  service=$(cfg ".jobs[$job_index].source.databases[$database_index].service")
  user=$(cfg ".jobs[$job_index].source.databases[$database_index].user")
  connect=$(cfg ".jobs[$job_index].source.databases[$database_index].connect")
  directory=$(cfg ".jobs[$job_index].source.databases[$database_index].directory")
  path=$(cfg ".jobs[$job_index].source.databases[$database_index].path")
  dumpfile="backfort_${backup_id}.dmp"
  logfile="backfort_${backup_id}.log"
  container_dump="${path%/}/$dumpfile"
  container_log="${path%/}/$logfile"

  # shellcheck disable=SC2016 # The fixed command expands values inside the container shell.
  if ! compose_exec_with_secret "$job_index" "$database_index" BACKFORT_ORACLE_PASSWORD "$service" \
    sh -c 'printf "%s\\n" "$BACKFORT_ORACLE_PASSWORD" | expdp "$1@$2" DIRECTORY="$3" DUMPFILE="$4" LOGFILE="$5" FULL=Y REUSE_DUMPFILES=Y' \
    backfort-expdp "$user" "$connect" "$directory" "$dumpfile" "$logfile" >/dev/null; then
    cleanup_compose_container_files "$job_index" "$service" "$container_dump" "$container_log"
    log error "kind=compose-dump engine=oracle service=$service message=export-failed"
    return 3
  fi
  container_id=$(compose_container_id "$job_index" "$service") || {
    cleanup_compose_container_files "$job_index" "$service" "$container_dump" "$container_log"
    log error "kind=compose-dump engine=oracle service=$service message=container-not-found"
    return 3
  }
  output="$snapshot_directory/full.dmp"
  if ! docker cp "$container_id:$container_dump" "$output"; then
    rm -f -- "$output"
    cleanup_compose_container_files "$job_index" "$service" "$container_dump" "$container_log"
    log error "kind=compose-dump engine=oracle service=$service message=copy-failed"
    return 3
  fi
  cleanup_compose_container_files "$job_index" "$service" "$container_dump" "$container_log"
}

snapshot_compose_databases() {
  local job_index=$1
  local backup_id=$2
  local snapshot_directory=$3
  local database_count database_index name engine output

  database_count=$(cfg ".jobs[$job_index].source.databases // [] | length")
  for ((database_index = 0; database_index < database_count; database_index++)); do
    name=$(cfg ".jobs[$job_index].source.databases[$database_index].name")
    engine=$(cfg ".jobs[$job_index].source.databases[$database_index].engine")
    output="$snapshot_directory/databases/$name"
    mkdir -p -- "$output"
    case "$engine" in
      postgres) snapshot_postgres_database "$job_index" "$database_index" "$output" ;;
      mysql|mariadb) snapshot_mysql_database "$job_index" "$database_index" "$output" ;;
      mssql) snapshot_mssql_database "$job_index" "$database_index" "$output" "$backup_id" ;;
      oracle) snapshot_oracle_database "$job_index" "$database_index" "$output" "$backup_id" ;;
      *) return 3 ;;
    esac || return 3
  done
}

snapshot_compose_volume() {
  local job_index=$1
  local logical_volume=$2
  local snapshot_directory=$3
  local helper_image docker_volume target

  helper_image=$(cfg ".jobs[$job_index].source.volume_helper_image")
  docker_volume=$(compose_volume_name "$job_index" "$logical_volume") || return 3
  target="$snapshot_directory/volumes/$logical_volume"
  mkdir -p -- "$target"
  # The helper stays networkless and read-only. DAC_READ_SEARCH is the minimum
  # capability needed for root in the helper to traverse Docker volume content
  # owned by an application UID (for example PostgreSQL's 0700 data directory).
  if ! docker run --rm --pull=never --network none --read-only --cap-drop ALL --cap-add DAC_READ_SEARCH \
    -v "$docker_volume:/source:ro" -v "$target:/backup:rw" "$helper_image" \
    tar --create --file /backup/data.tar --directory /source .; then
    log error "kind=compose-volume job=$(cfg ".jobs[$job_index].name") volume=$logical_volume message=snapshot-failed"
    return 3
  fi
}

snapshot_compose_bind_mount() {
  local job_index=$1
  local bind_index=$2
  local snapshot_directory=$3
  local project_dir name relative_path source target

  project_dir=$(cfg ".jobs[$job_index].source.project_dir")
  name=$(cfg ".jobs[$job_index].source.bind_mounts[$bind_index].name")
  relative_path=$(cfg ".jobs[$job_index].source.bind_mounts[$bind_index].path")
  source="$project_dir/$relative_path"
  target="$snapshot_directory/bind-mounts/$name"
  mkdir -p -- "$target"
  if [[ -d $source ]]; then
    if tar --create --file - --directory "$source" . | tar --extract --file - --directory "$target"; then
      return 0
    fi
  elif cp --preserve=mode,timestamps -- "$source" "$target/$(basename -- "$source")"; then
    return 0
  fi
  {
    log error "kind=compose-bind-mount job=$(cfg ".jobs[$job_index].name") name=$name message=snapshot-failed"
    return 3
  }
}

prepare_compose_snapshot() {
  local job_index=$1
  local backup_id=$2
  local snapshot_directory=$3
  local project_dir files_count file_index file source_file target_file
  local volume_count volume_index logical_volume bind_count bind_index

  mkdir -p -- "$snapshot_directory/compose" "$snapshot_directory/volumes" \
    "$snapshot_directory/bind-mounts" "$snapshot_directory/databases"
  project_dir=$(cfg ".jobs[$job_index].source.project_dir")
  files_count=$(cfg ".jobs[$job_index].source.files | length")
  for ((file_index = 0; file_index < files_count; file_index++)); do
    file=$(cfg ".jobs[$job_index].source.files[$file_index]")
    source_file="$project_dir/$file"
    target_file="$snapshot_directory/compose/$file"
    mkdir -p -- "$(dirname -- "$target_file")"
    cp --preserve=mode,timestamps -- "$source_file" "$target_file" || return 3
  done

  volume_count=$(cfg ".jobs[$job_index].source.volumes // [] | length")
  for ((volume_index = 0; volume_index < volume_count; volume_index++)); do
    logical_volume=$(cfg ".jobs[$job_index].source.volumes[$volume_index]")
    snapshot_compose_volume "$job_index" "$logical_volume" "$snapshot_directory" || return 3
  done

  bind_count=$(cfg ".jobs[$job_index].source.bind_mounts // [] | length")
  for ((bind_index = 0; bind_index < bind_count; bind_index++)); do
    snapshot_compose_bind_mount "$job_index" "$bind_index" "$snapshot_directory" || return 3
  done

  snapshot_compose_databases "$job_index" "$backup_id" "$snapshot_directory" || return 3
}

pack_files_job() {
  local job_index=$1
  local tar_file=$2
  local list_file="$WORK_DIRECTORY/source-paths.list"
  local paths_count path_index path exclude_count exclude_index exclude follow_symlinks
  local -a tar_arguments

  paths_count=$(cfg ".jobs[$job_index].source.paths | length")
  : >"$list_file"
  for ((path_index = 0; path_index < paths_count; path_index++)); do
    path=$(cfg ".jobs[$job_index].source.paths[$path_index]")
    printf '%s\0' "${path#/}" >>"$list_file"
  done

  tar_arguments=(--create --file "$tar_file" --directory / --transform 's,^,data/,')
  follow_symlinks=$(cfg ".jobs[$job_index].source.follow_symlinks // false")
  [[ $follow_symlinks == true ]] && tar_arguments+=(--dereference)

  exclude_count=$(cfg ".jobs[$job_index].source.exclude // [] | length")
  for ((exclude_index = 0; exclude_index < exclude_count; exclude_index++)); do
    exclude=$(cfg ".jobs[$job_index].source.exclude[$exclude_index]")
    [[ $exclude != *$'\n'* && $exclude != *$'\r'* ]] || config_error "newline-in-exclude-pattern"
    tar_arguments+=("--exclude=$exclude")
  done
  tar_arguments+=(--null --files-from "$list_file")

  if ! tar "${tar_arguments[@]+"${tar_arguments[@]}"}"; then
    log error "kind=pack message=source-pack-failed"
    return 3
  fi
}

pack_compose_job() {
  local job_index=$1
  local tar_file=$2
  local backup_id=$3
  local snapshot_directory="$WORK_DIRECTORY/compose-snapshot"

  prepare_compose_snapshot "$job_index" "$backup_id" "$snapshot_directory" || return 3
  if ! tar --create --file "$tar_file" --directory "$snapshot_directory" --transform 's,^\.,data,' .; then
    log error "kind=pack message=compose-snapshot-pack-failed"
    return 3
  fi
}

yaml_quote() {
  local value=$1
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

safe_manifest_entry_path() {
  local path=$1
  [[ -n $path && $path != /* && $path != . && $path != .. && $path != ./* && $path != ../* \
    && $path != */../* && $path != */.. && $path != *$'\n'* && $path != *$'\r'* && $path != *$'\t'* ]]
}

hash_regular_archive_files() {
  local tar_file=$1
  local output=$2
  local helper="$WORK_DIRECTORY/archive-file-hash.sh"

  cat >"$helper" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

case "${TAR_FILETYPE:-}:${TAR_FILENAME:-}" in
  f:data/*)
    digest=$(sha256sum | awk '{print $1}')
    [[ $digest =~ ^[a-f0-9]{64}$ ]] || exit 1
    printf '%s\t%s\0' "$digest" "$TAR_FILENAME"
    ;;
  *) cat >/dev/null ;;
esac
EOF
  chmod 0700 "$helper"
  if ! tar --extract --to-command="$helper" --file "$tar_file" >"$output"; then
    rm -f -- "$helper"
    return 1
  fi
  rm -f -- "$helper"
}

manifest_entries_from_tar() {
  local tar_file=$1
  local output=$2
  local listing="$WORK_DIRECTORY/manifest-entries.list"
  local hash_records="$WORK_DIRECTORY/manifest-file-hashes.nul"
  local mode _owner size date_value time_value archive_path entry_path entry_type
  local hash_record file_hash hashed_archive_path
  local count=0

  : >"$output"
  tar --list --verbose --full-time --numeric-owner --quoting-style=literal --file "$tar_file" >"$listing" || return 1
  hash_regular_archive_files "$tar_file" "$hash_records" || return 1
  exec 3<"$hash_records"
  while IFS=' ' read -r mode _owner size date_value time_value archive_path; do
    [[ $archive_path == data || $archive_path == data/ ]] && continue
    [[ $archive_path == data/* ]] || return 1
    entry_path=${archive_path#data/}
    case "${mode:0:1}" in
      -) entry_type='file' ;;
      d) entry_type='directory'; entry_path=${entry_path%/} ;;
      l) entry_type='symlink'; entry_path=${entry_path%%' -> '*} ;;
      h) entry_type='hardlink'; entry_path=${entry_path%%' link to '*} ;;
      *) return 1 ;;
    esac
    [[ $size =~ ^[0-9]+$ ]] || return 1
    safe_manifest_entry_path "$entry_path" || return 1
    {
      printf '%s\n' "- path: $(yaml_quote "$entry_path")"
      printf '%s\n' "  type: $(yaml_quote "$entry_type")"
      printf '%s\n' "  size: $size"
      printf '%s\n' "  mtime: $(yaml_quote "$date_value $time_value")"
      if [[ $entry_type == file ]]; then
        IFS= read -r -d '' hash_record <&3 || return 1
        [[ $hash_record == *$'\t'* ]] || return 1
        file_hash=${hash_record%%$'\t'*}
        hashed_archive_path=${hash_record#*$'\t'}
        [[ $file_hash =~ ^[a-f0-9]{64}$ && $hashed_archive_path == "$archive_path" ]] || return 1
        printf '%s\n' "  sha256: $(yaml_quote "$file_hash")"
      fi
    } >>"$output"
    count=$((count + 1))
  done <"$listing"

  if IFS= read -r -d '' <&3; then
    exec 3<&-
    return 1
  fi
  exec 3<&-

  if ((count == 0)); then
    printf '[]\n' >"$output"
  fi
  yq eval '.' "$output" >/dev/null
}

pack_job() {
  local job_index=$1
  local tar_file=$2
  local backup_id=$3
  local created_at=$4
  local payload_name=$5
  local manifest=$6
  local entries_file="$WORK_DIRECTORY/manifest-entries.yaml"
  local source_type

  source_type=$(cfg ".jobs[$job_index].source.type")
  case "$source_type" in
    files) pack_files_job "$job_index" "$tar_file" ;;
    docker_compose) pack_compose_job "$job_index" "$tar_file" "$backup_id" ;;
    *) return 3 ;;
  esac || return 3

  if ! manifest_entries_from_tar "$tar_file" "$entries_file" \
    || ! create_manifest "$job_index" "$backup_id" "$created_at" "$payload_name" "$entries_file" "$manifest"; then
    log error "kind=manifest job=$(cfg ".jobs[$job_index].name") message=create-failed"
    return 3
  fi
  if ! tar --append --file "$tar_file" --directory "$WORK_DIRECTORY" "$(basename -- "$manifest")"; then
    log error "kind=pack message=manifest-pack-failed"
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
  local env_name password_env recipient recipient_count recipient_index
  local -a age_arguments gpg_arguments

  case "$method" in
    none)
      [[ $input == "$output" ]] || cp -- "$input" "$output"
      ;;
    age)
      age_arguments=(--encrypt)
      env_name=$(cfg ".jobs[$job_index].encryption.recipient_env // \"\"")
      if [[ -n $env_name ]]; then
        recipient=${!env_name-}
        age_arguments+=(--recipient "$recipient")
      else
        recipient_count=$(cfg ".jobs[$job_index].encryption.recipients_env // [] | length")
        for ((recipient_index = 0; recipient_index < recipient_count; recipient_index++)); do
          env_name=$(cfg ".jobs[$job_index].encryption.recipients_env[$recipient_index]")
          recipient=${!env_name-}
          age_arguments+=(--recipient "$recipient")
        done
      fi
      if ! age "${age_arguments[@]+"${age_arguments[@]}"}" --output "$output" "$input"; then
        return 3
      fi
      ;;
    gpg)
      password_env=$(cfg ".jobs[$job_index].encryption.password_env // \"\"")
      if [[ -n $password_env ]]; then
        local secret=${!password_env-}
        if ! gpg --batch --yes --pinentry-mode loopback --cipher-algo AES256 --compress-algo none \
          --s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712 \
          --passphrase-fd 3 --symmetric --output "$output" "$input" 3< <(printf '%s' "$secret"); then
          secret=""
          return 3
        fi
        secret=""
      else
        gpg_arguments=(--batch --yes --no-tty --no-auto-key-retrieve --trust-model always --output "$output")
        env_name=$(cfg ".jobs[$job_index].encryption.recipient_env // \"\"")
        if [[ -n $env_name ]]; then
          recipient=${!env_name-}
          gpg_arguments+=(--recipient "$recipient")
        else
          recipient_count=$(cfg ".jobs[$job_index].encryption.recipients_env // [] | length")
          for ((recipient_index = 0; recipient_index < recipient_count; recipient_index++)); do
            env_name=$(cfg ".jobs[$job_index].encryption.recipients_env[$recipient_index]")
            recipient=${!env_name-}
            gpg_arguments+=(--recipient "$recipient")
          done
        fi
        if ! gpg "${gpg_arguments[@]+"${gpg_arguments[@]}"}" --encrypt "$input"; then
          return 3
        fi
      fi
      ;;
  esac
}

signature_filename() {
  local backup_id=$1
  printf '%s.minisig\n' "$backup_id"
}

sign_payload() {
  local job_index=$1
  local payload=$2
  local signature=$3
  local method env_name secret_key

  method=$(cfg ".jobs[$job_index].signing.method // \"none\"")
  [[ $method == minisign ]] || return 0
  env_name=$(cfg ".jobs[$job_index].signing.secret_key_env")
  secret_key=${!env_name-}
  if ! minisign -S -q -s "$secret_key" -m "$payload" -x "$signature"; then
    secret_key=""
    return 3
  fi
  secret_key=""
}

atomic_copy() {
  local source=$1
  local destination=$2
  local temporary="${destination}.partial.$$"
  rm -f -- "$temporary"
  cp -- "$source" "$temporary" && mv -- "$temporary" "$destination"
}

sync_published_local_paths() {
  local destination_name=$1
  local stage=$2
  shift 2

  # GNU sync -f flushes the filesystems holding these paths.  Publish the
  # commit marker only after the payload evidence has reached durable storage,
  # then flush the marker and its containing directory as a separate commit.
  if ! sync -f -- "$@"; then
    log error "kind=publish destination=$destination_name message=durability-sync-failed stage=$stage"
    return 1
  fi
}

prometheus_nonnegative_integer() {
  local value=${1:-}

  [[ $value =~ ^[0-9]+$ ]] || value=0
  printf '%s\n' "$value"
}

write_prometheus_metrics() {
  local job=$1
  local exit_code=$2
  local successful failed size duration duration_value recorded_at success_value
  local temporary final labels

  [[ -n $PROMETHEUS_TEXTFILE_DIRECTORY ]] || return 0
  if [[ ! -d $PROMETHEUS_TEXTFILE_DIRECTORY || -L $PROMETHEUS_TEXTFILE_DIRECTORY \
    || ! -w $PROMETHEUS_TEXTFILE_DIRECTORY ]]; then
    log warning "kind=metrics message=prometheus-textfile-directory-not-usable path=$PROMETHEUS_TEXTFILE_DIRECTORY"
    return 1
  fi

  case "$exit_code" in
    0) success_value=1 ;;
    *) success_value=0 ;;
  esac
  successful=$(prometheus_nonnegative_integer "${BACKFORT_METRICS_SUCCESSFUL_COPIES:-}")
  failed=$(prometheus_nonnegative_integer "${BACKFORT_METRICS_FAILED_COPIES:-}")
  size=$(prometheus_nonnegative_integer "${BACKFORT_EVENT_SIZE:-}")
  duration_value=${BACKFORT_EVENT_DURATION:-}
  duration_value=${duration_value%s}
  duration=$(prometheus_nonnegative_integer "$duration_value")
  recorded_at=$(date -u +%s)
  final="$PROMETHEUS_TEXTFILE_DIRECTORY/backfort_${job}.prom"
  labels="host=\"$HOST_ID\",job=\"$job\""

  if ! temporary=$(mktemp -- "$PROMETHEUS_TEXTFILE_DIRECTORY/.backfort_${job}.prom.XXXXXX"); then
    log warning "kind=metrics message=prometheus-textfile-create-failed job=$job"
    return 1
  fi
  if ! {
    printf '%s\n' '# HELP backfort_last_run_success Whether the latest job run completed fully (1) or not (0).'
    printf '%s\n' '# TYPE backfort_last_run_success gauge'
    printf 'backfort_last_run_success{%s} %s\n' "$labels" "$success_value"
    printf '%s\n' '# HELP backfort_last_run_exit_code Backfort exit code from the latest job run.'
    printf '%s\n' '# TYPE backfort_last_run_exit_code gauge'
    printf 'backfort_last_run_exit_code{%s} %s\n' "$labels" "$exit_code"
    printf '%s\n' '# HELP backfort_last_run_timestamp_seconds Unix timestamp when the latest job run finished.'
    printf '%s\n' '# TYPE backfort_last_run_timestamp_seconds gauge'
    printf 'backfort_last_run_timestamp_seconds{%s} %s\n' "$labels" "$recorded_at"
    printf '%s\n' '# HELP backfort_last_run_duration_seconds Duration of the latest job run in seconds.'
    printf '%s\n' '# TYPE backfort_last_run_duration_seconds gauge'
    printf 'backfort_last_run_duration_seconds{%s} %s\n' "$labels" "$duration"
    printf '%s\n' '# HELP backfort_last_backup_size_bytes Size of the latest created backup payload in bytes.'
    printf '%s\n' '# TYPE backfort_last_backup_size_bytes gauge'
    printf 'backfort_last_backup_size_bytes{%s} %s\n' "$labels" "$size"
    printf '%s\n' '# HELP backfort_last_successful_copies Number of destinations that accepted the latest backup.'
    printf '%s\n' '# TYPE backfort_last_successful_copies gauge'
    printf 'backfort_last_successful_copies{%s} %s\n' "$labels" "$successful"
    printf '%s\n' '# HELP backfort_last_failed_copies Number of destinations that rejected the latest backup.'
    printf '%s\n' '# TYPE backfort_last_failed_copies gauge'
    printf 'backfort_last_failed_copies{%s} %s\n' "$labels" "$failed"
  } >"$temporary"; then
    rm -f -- "$temporary"
    log warning "kind=metrics message=prometheus-textfile-write-failed job=$job"
    return 1
  fi
  if ! chmod 0644 -- "$temporary" || ! mv -f -- "$temporary" "$final"; then
    rm -f -- "$temporary"
    log warning "kind=metrics message=prometheus-textfile-publish-failed job=$job"
    return 1
  fi
  log info "event=prometheus-metrics-written job=$job file=$final"
}

destination_object_exists() {
  local destination_index=$1
  local filename=$2
  local type object root listed

  type=$(destination_type "$destination_index")
  case "$type" in
    local)
      object=$(destination_object "$destination_index" "$filename")
      [[ -f $object && ! -L $object ]]
      ;;
    rclone)
      require_command rclone
      root=$(destination_rclone_root "$destination_index")
      while IFS= read -r listed; do
        [[ $listed == "$filename" ]] && return 0
      done < <(rclone lsf --files-only --format p "$root" 2>/dev/null)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

publish_to_local_destination() {
  local destination_index=$1
  local backup_id=$2
  local payload=$3
  local metadata=$4
  local checksum=$5
  local signature=${6:-}
  local destination_name destination_path payload_name
  local final_payload final_metadata final_checksum final_signature final_complete marker_source
  local -a published_objects

  destination_name=$(cfg ".destinations[$destination_index].name")
  destination_path=$(destination_local_path "$destination_index")
  payload_name=$(basename -- "$payload")
  final_payload="$destination_path/$payload_name"
  final_metadata="$destination_path/$backup_id.metadata.json"
  final_checksum="$destination_path/$backup_id.sha256"
  [[ -z $signature ]] || final_signature="$destination_path/$(basename -- "$signature")"
  final_complete="$destination_path/$backup_id.complete"
  marker_source="$WORK_DIRECTORY/$backup_id.complete"
  published_objects=("$final_payload" "$final_metadata" "$final_checksum")
  [[ -z $signature ]] || published_objects+=("$final_signature")

  if ! mkdir -p -- "$destination_path"; then
    log error "kind=publish destination=$destination_name message=create-directory-failed"
    return 3
  fi
  if [[ -e $final_payload || -e $final_metadata || -e $final_checksum || -e $final_complete ]] \
    || [[ -n $signature && -e $final_signature ]]; then
    log error "kind=publish destination=$destination_name message=backup-id-already-exists"
    return 3
  fi

  if atomic_copy "$payload" "$final_payload" \
    && atomic_copy "$metadata" "$final_metadata" \
    && atomic_copy "$checksum" "$final_checksum" \
    && { [[ -z $signature ]] || atomic_copy "$signature" "$final_signature"; }; then
    if ! sync_published_local_paths "$destination_name" artifacts \
      "${published_objects[@]+"${published_objects[@]}"}"; then
      rm -f -- "${published_objects[@]+"${published_objects[@]}"}"
      return 3
    fi
  else
    rm -f -- "${published_objects[@]+"${published_objects[@]}"}"
    rm -f -- "$destination_path/$payload_name.partial.$$" \
      "$destination_path/$backup_id.metadata.json.partial.$$" \
      "$destination_path/$backup_id.sha256.partial.$$" \
      "$destination_path/$(signature_filename "$backup_id").partial.$$" \
      "$destination_path/$backup_id.complete.partial.$$"
    log error "kind=publish destination=$destination_name message=atomic-publish-failed"
    return 3
  fi

  if ! printf '%s\n' "$backup_id" >"$marker_source" \
    || ! atomic_copy "$marker_source" "$final_complete"; then
    rm -f -- "$final_complete" "${published_objects[@]+"${published_objects[@]}"}"
    log error "kind=publish destination=$destination_name message=atomic-publish-failed"
    return 3
  fi
  if ! sync_published_local_paths "$destination_name" commit-marker "$final_complete" "$destination_path"; then
    rm -f -- "$final_complete" "${published_objects[@]+"${published_objects[@]}"}"
    return 3
  fi

  log info "event=backup-published destination=$destination_name backup_id=$backup_id"
  return 0
}

publish_to_rclone_destination() {
  local destination_index=$1
  local backup_id=$2
  local payload=$3
  local metadata=$4
  local checksum=$5
  local signature=${6:-}
  local destination_name payload_name marker_source
  local final_payload final_metadata final_checksum final_signature final_complete

  require_command rclone
  destination_name=$(cfg ".destinations[$destination_index].name")
  payload_name=$(basename -- "$payload")
  final_payload=$(destination_object "$destination_index" "$payload_name")
  final_metadata=$(destination_object "$destination_index" "$backup_id.metadata.json")
  final_checksum=$(destination_object "$destination_index" "$backup_id.sha256")
  [[ -z $signature ]] || final_signature=$(destination_object "$destination_index" "$(basename -- "$signature")")
  final_complete=$(destination_object "$destination_index" "$backup_id.complete")
  marker_source="$WORK_DIRECTORY/$backup_id.complete"

  if destination_object_exists "$destination_index" "$payload_name" \
    || destination_object_exists "$destination_index" "$backup_id.metadata.json" \
    || destination_object_exists "$destination_index" "$backup_id.sha256" \
    || { [[ -n $signature ]] && destination_object_exists "$destination_index" "$(basename -- "$signature")"; } \
    || destination_object_exists "$destination_index" "$backup_id.complete"; then
    log error "kind=publish destination=$destination_name message=backup-id-already-exists"
    return 3
  fi

  printf '%s\n' "$backup_id" >"$marker_source"
  if rclone copyto "$payload" "$final_payload" \
    && rclone copyto "$metadata" "$final_metadata" \
    && rclone copyto "$checksum" "$final_checksum" \
    && { [[ -z $signature ]] || rclone copyto "$signature" "$final_signature"; } \
    && rclone copyto "$marker_source" "$final_complete"; then
    log info "event=backup-published destination=$destination_name backup_id=$backup_id"
    return 0
  fi

  # A marker is only visible after every required object is present.  Cleanup
  # is best-effort because a write-only remote credential may not delete.
  rclone deletefile "$final_complete" >/dev/null 2>&1 || true
  rclone deletefile "$final_payload" >/dev/null 2>&1 || true
  rclone deletefile "$final_metadata" >/dev/null 2>&1 || true
  rclone deletefile "$final_checksum" >/dev/null 2>&1 || true
  [[ -z $signature ]] || rclone deletefile "$final_signature" >/dev/null 2>&1 || true
  log error "kind=publish destination=$destination_name message=rclone-publish-failed"
  return 3
}

publish_to_destination() {
  local destination_index=$1
  local destination_type_value
  destination_type_value=$(destination_type "$destination_index")
  case "$destination_type_value" in
    local)
      publish_to_local_destination "$@"
      ;;
    rclone)
      publish_to_rclone_destination "$@"
      ;;
    *)
      log error "kind=publish message=unsupported-destination-type type=$destination_type_value"
      return 3
      ;;
  esac
}

run_job_backup() {
  local job_index=$1
  local configured_backup_id=${2:-}
  local job_name source_type compression compression_level encryption signing created_at backup_id extension
  local manifest tar_file compressed_file payload_file checksum_file signature_file payload_name hash
  local destination_count destination_position destination_name destination_index minimum_copies started_seconds payload_size
  local successful=0 failed=0 successful_destinations='' failed_destinations=''

  job_name=$(cfg ".jobs[$job_index].name")
  source_type=$(cfg ".jobs[$job_index].source.type")
  compression=$(cfg ".jobs[$job_index].compression.method // \"gzip\"")
  compression_level=$(cfg ".jobs[$job_index].compression.level // 6")
  encryption=$(cfg ".jobs[$job_index].encryption.method // \"none\"")
  signing=$(cfg ".jobs[$job_index].signing.method // \"none\"")
  minimum_copies=$(cfg ".jobs[$job_index].success.min_copies // 1")

  if [[ $DRY_RUN == true ]]; then
    log info "event=plan job=$job_name source=$source_type compression=$compression encryption=$encryption signing=$signing min_copies=$minimum_copies"
    destination_count=$(cfg ".jobs[$job_index].destinations | length")
    for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
      destination_name=$(cfg ".jobs[$job_index].destinations[$destination_position]")
      log info "event=plan-publish job=$job_name destination=$destination_name"
    done
    return 0
  fi

  started_seconds=$(date -u +%s)
  created_at=$(timestamp)
  backup_id=${configured_backup_id:-$(new_backup_id "$job_name")}
  BACKFORT_EVENT_JOB=$job_name
  BACKFORT_EVENT_ID=$backup_id
  BACKFORT_EVENT_SIZE=''
  BACKFORT_EVENT_DURATION=''
  BACKFORT_EVENT_DESTINATIONS=''
  BACKFORT_EVENT_FAILED_DESTINATIONS=''
  BACKFORT_EVENT_STAGE=''
  BACKFORT_EVENT_ERROR=''
  BACKFORT_EVENT_EXTRA=''
  BACKFORT_METRICS_SUCCESSFUL_COPIES=0
  BACKFORT_METRICS_FAILED_COPIES=0
  if ! make_work_directory; then
    BACKFORT_EVENT_STAGE='prepare'
    BACKFORT_EVENT_ERROR='temporary work directory could not be created'
    BACKFORT_EVENT_DURATION="$(( $(date -u +%s) - started_seconds ))s"
    return 3
  fi
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
  signature_file=""

  log info "event=backup-started job=$job_name backup_id=$backup_id"
  if ! pack_job "$job_index" "$tar_file" "$backup_id" "$created_at" "$payload_name" "$manifest"; then
    BACKFORT_EVENT_STAGE='pack'
    BACKFORT_EVENT_ERROR='backup packaging failed'
    BACKFORT_EVENT_DURATION="$(( $(date -u +%s) - started_seconds ))s"
    cleanup_work_directory
    return 3
  fi

  if [[ $compression != none ]]; then
    if ! compress_tar "$compression" "$compression_level" "$tar_file" "$compressed_file"; then
      log error "kind=compress job=$job_name method=$compression message=failed"
      BACKFORT_EVENT_STAGE='compress'
      BACKFORT_EVENT_ERROR='backup compression failed'
      BACKFORT_EVENT_DURATION="$(( $(date -u +%s) - started_seconds ))s"
      cleanup_work_directory
      return 3
    fi
    rm -f -- "$tar_file"
  fi

  if [[ $encryption != none ]]; then
    if ! encrypt_artifact "$encryption" "$job_index" "$compressed_file" "$payload_file"; then
      log error "kind=encrypt job=$job_name method=$encryption message=failed"
      BACKFORT_EVENT_STAGE='encrypt'
      BACKFORT_EVENT_ERROR='backup encryption failed'
      BACKFORT_EVENT_DURATION="$(( $(date -u +%s) - started_seconds ))s"
      cleanup_work_directory
      return 3
    fi
    rm -f -- "$compressed_file"
  fi

  hash=$(sha256sum "$payload_file" | awk '{print $1}')
  printf '%s  %s\n' "$hash" "$payload_name" >"$checksum_file"
  if [[ $signing == minisign ]]; then
    signature_file="$WORK_DIRECTORY/$(signature_filename "$backup_id")"
    if ! sign_payload "$job_index" "$payload_file" "$signature_file"; then
      log error "kind=sign job=$job_name method=$signing message=failed"
      BACKFORT_EVENT_STAGE=sign
      BACKFORT_EVENT_ERROR='backup signing failed'
      BACKFORT_EVENT_DURATION="$(( $(date -u +%s) - started_seconds ))s"
      cleanup_work_directory
      return 3
    fi
  fi

  if ! payload_size=$(stat --format='%s' "$payload_file"); then
    payload_size=unknown
  fi

  destination_count=$(cfg ".jobs[$job_index].destinations | length")
  for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
    destination_name=$(cfg ".jobs[$job_index].destinations[$destination_position]")
    destination_index=$(find_destination_index "$destination_name")
    if publish_to_destination "$destination_index" "$backup_id" "$payload_file" "$manifest" "$checksum_file" "$signature_file"; then
      successful=$((successful + 1))
      successful_destinations+="${successful_destinations:+,}$destination_name"
    else
      failed=$((failed + 1))
      failed_destinations+="${failed_destinations:+,}$destination_name"
    fi
  done

  BACKFORT_EVENT_SIZE=$payload_size
  BACKFORT_EVENT_DURATION="$(( $(date -u +%s) - started_seconds ))s"
  BACKFORT_EVENT_DESTINATIONS=$successful_destinations
  BACKFORT_EVENT_FAILED_DESTINATIONS=$failed_destinations
  BACKFORT_EVENT_STAGE='publish'
  BACKFORT_METRICS_SUCCESSFUL_COPIES=$successful
  BACKFORT_METRICS_FAILED_COPIES=$failed
  cleanup_work_directory
  if ((successful == 0)); then
    log error "event=backup-failed job=$job_name backup_id=$backup_id reason=no-destination-succeeded"
    BACKFORT_EVENT_ERROR='no destination accepted a completed backup'
    return 3
  fi
  if ((successful < minimum_copies)); then
    log error "event=backup-failed job=$job_name backup_id=$backup_id reason=min-copies-not-reached successful=$successful required=$minimum_copies failed=$failed"
    BACKFORT_EVENT_ERROR='minimum successful copies not reached'
    return 3
  fi
  if ((failed > 0)); then
    log warning "event=backup-partial job=$job_name backup_id=$backup_id successful=$successful failed=$failed required=$minimum_copies"
    BACKFORT_EVENT_ERROR='one or more destinations rejected the backup'
    return 1
  fi
  log info "event=backup-succeeded job=$job_name backup_id=$backup_id destinations=$successful"
  return 0
}

hook_result_name() {
  local exit_code=$1

  case "$exit_code" in
    0) printf '%s\n' success ;;
    1) printf '%s\n' partial ;;
    130|143) printf '%s\n' interrupted ;;
    *) printf '%s\n' failure ;;
  esac
}

plan_job_hooks() {
  local job_index=$1
  local job_name=$2
  local phase script argument_count

  for phase in pre post; do
    job_hook_configured "$job_index" "$phase" || continue
    script=$(cfg ".jobs[$job_index].hooks.$phase.path")
    argument_count=$(cfg "(.jobs[$job_index].hooks.$phase.args // []) | length")
    log info "event=plan-hook job=$job_name phase=$phase path=$script args_count=$argument_count"
  done
}

run_job_hook() {
  local job_index=$1
  local job_name=$2
  local backup_id=$3
  local phase=$4
  local hook_result=$5
  local hook_exit_code=$6
  local script argument_count argument_index argument hook_status
  local -a hook_arguments=()

  job_hook_configured "$job_index" "$phase" || return 0
  script=$(cfg ".jobs[$job_index].hooks.$phase.path")
  argument_count=$(cfg "(.jobs[$job_index].hooks.$phase.args // []) | length")
  for ((argument_index = 0; argument_index < argument_count; argument_index++)); do
    argument=$(cfg ".jobs[$job_index].hooks.$phase.args[$argument_index]")
    hook_arguments+=("$argument")
  done

  log info "event=hook-started job=$job_name backup_id=$backup_id phase=$phase args_count=$argument_count"
  if (
    cd /
    exec env -i \
      PATH="$BACKFORT_HOOK_SAFE_PATH" \
      LANG=C \
      BACKFORT_HOOK_PHASE="$phase" \
      BACKFORT_HOOK_JOB="$job_name" \
      BACKFORT_HOOK_BACKUP_ID="$backup_id" \
      BACKFORT_HOOK_CONFIG_FILE="$CONFIG_FILE" \
      BACKFORT_HOOK_SOURCE_TYPE="$(cfg ".jobs[$job_index].source.type")" \
      BACKFORT_HOOK_RESULT="$hook_result" \
      BACKFORT_HOOK_EXIT_CODE="$hook_exit_code" \
      "$script" "${hook_arguments[@]+"${hook_arguments[@]}"}"
  ); then
    log info "event=hook-succeeded job=$job_name backup_id=$backup_id phase=$phase"
    return 0
  else
    hook_status=$?
    log error "kind=hook job=$job_name backup_id=$backup_id phase=$phase exit_code=$hook_status message=failed"
    return "$hook_status"
  fi
}

run_job() {
  local job_index=$1
  local job_name backup_id hook_result hook_exit_code post_status pre_status

  job_name=$(cfg ".jobs[$job_index].name")
  if [[ $DRY_RUN == true ]]; then
    plan_job_hooks "$job_index" "$job_name"
    run_job_backup "$job_index"
    return
  fi

  backup_id=$(new_backup_id "$job_name")
  if job_hook_configured "$job_index" post; then
    POST_HOOK_PENDING=true
    POST_HOOK_JOB_INDEX=$job_index
    POST_HOOK_JOB_NAME=$job_name
    POST_HOOK_BACKUP_ID=$backup_id
  fi

  PRE_HOOK_RUNNING=true
  if run_job_hook "$job_index" "$job_name" "$backup_id" pre starting 0; then
    pre_status=0
  else
    pre_status=$?
  fi
  PRE_HOOK_RUNNING=false
  if ((pre_status != 0)); then
    BACKFORT_EVENT_JOB=$job_name
    BACKFORT_EVENT_ID=$backup_id
    BACKFORT_EVENT_SIZE=''
    BACKFORT_EVENT_DURATION=''
    BACKFORT_EVENT_DESTINATIONS=''
    BACKFORT_EVENT_FAILED_DESTINATIONS=''
    BACKFORT_EVENT_STAGE='pre-hook'
    BACKFORT_EVENT_ERROR='pre hook failed'
    BACKFORT_EVENT_EXTRA=''
    BACKFORT_METRICS_SUCCESSFUL_COPIES=0
    BACKFORT_METRICS_FAILED_COPIES=0
    hook_result=failure
    hook_exit_code=3
  elif run_job_backup "$job_index" "$backup_id"; then
    hook_result=success
    hook_exit_code=0
  else
    hook_exit_code=$?
    hook_result=$(hook_result_name "$hook_exit_code")
  fi

  if job_hook_configured "$job_index" post; then
    if run_job_hook "$job_index" "$job_name" "$backup_id" post "$hook_result" "$hook_exit_code"; then
      post_status=0
    else
      post_status=$?
    fi
    POST_HOOK_PENDING=false
    if ((post_status != 0)); then
      BACKFORT_EVENT_STAGE='post-hook'
      BACKFORT_EVENT_ERROR='post hook failed; a backup may still be complete'
      return 3
    fi
  fi

  return "$hook_exit_code"
}

run_command() {
  # A destination is an independent publish attempt.  Its availability is
  # checked by publish_to_destination so one failed copy can yield a partial
  # result instead of preventing every other destination from receiving data.
  local index name result=0 job_result preflight_status

  # A bad collector directory cannot receive a metric. It still becomes a
  # failure event for every selected persistent job, so operators are alerted
  # instead of losing the scheduled run silently.
  if (preflight_prometheus_metrics); then
    :
  else
    preflight_status=$?
    if [[ $DRY_RUN == false ]]; then
      for ((index = 0; index < JOB_COUNT; index++)); do
        name=$(cfg ".jobs[$index].name")
        [[ -z $SELECTED_JOB || $name == "$SELECTED_JOB" ]] || continue
        set_preflight_failure_event "$name" "$preflight_status"
        BACKFORT_EVENT_ERROR='Prometheus metrics preflight failed; see Backfort log'
        bf_notify_result run 3
      done
    fi
    return 3
  fi

  if [[ $DRY_RUN == false ]]; then
    require_command flock
    if ! acquire_lock; then
      return 3
    fi
  fi

  for ((index = 0; index < JOB_COUNT; index++)); do
    name=$(cfg ".jobs[$index].name")
    [[ -z $SELECTED_JOB || $name == "$SELECTED_JOB" ]] || continue
    # config_error deliberately exits with 2 for strict commands such as
    # doctor. Run preflight in a subshell here so a single job can instead be
    # recorded as an operational failure and the other selected jobs can run.
    if (preflight_job "$index" false); then
      preflight_status=0
    else
      preflight_status=$?
    fi
    if ((preflight_status != 0)); then
      job_result=3
      set_preflight_failure_event "$name" "$preflight_status"
    elif run_job "$index"; then
      job_result=0
    else
      job_result=$?
    fi
    if [[ $DRY_RUN == false ]]; then
      write_prometheus_metrics "$name" "$job_result" || true
      bf_notify_result run "$job_result"
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

destination_marker_value() {
  local destination_index=$1
  local backup_id=$2
  local type object value
  type=$(destination_type "$destination_index")
  object=$(destination_object "$destination_index" "$backup_id.complete")
  case "$type" in
    local)
      IFS= read -r value <"$object" || return 1
      printf '%s\n' "$value"
      ;;
    rclone)
      require_command rclone
      rclone cat "$object"
      ;;
    *) return 1 ;;
  esac
}

destination_pinned_marker_value() {
  local destination_index=$1
  local backup_id=$2
  local type object

  type=$(destination_type "$destination_index")
  object=$(destination_object "$destination_index" "$backup_id.pinned")
  case "$type" in
    local)
      [[ -f $object && ! -L $object ]] || return 1
      cat -- "$object"
      ;;
    rclone)
      require_command rclone
      rclone cat "$object"
      ;;
    *) return 1 ;;
  esac
}

backup_is_pinned() {
  local destination_index=$1
  local backup_id=$2

  destination_object_exists "$destination_index" "$backup_id.pinned"
}

pinned_marker_reason() {
  local destination_index=$1
  local backup_id=$2
  local marker timestamp_value reason

  # The sentinel keeps command substitution from stripping trailing newlines,
  # so a malformed multi-line marker cannot be mistaken for a valid one-line
  # marker with an empty reason.
  marker=$(destination_pinned_marker_value "$destination_index" "$backup_id" && printf '\036') || return 1
  [[ $marker == *$'\036' ]] || return 1
  marker=${marker%$'\036'}
  [[ $marker != *$'\036'* ]] || return 1
  [[ $marker != *$'\r'* ]] || return 1
  [[ $marker != *$'\n'* || $marker == *$'\n' ]] || return 1
  marker=${marker%$'\n'}
  [[ $marker != *$'\n'* ]] || return 1
  (( ${#marker} >= 20 )) || return 1
  timestamp_value=${marker:0:20}
  [[ $timestamp_value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1

  if ((${#marker} == 20)); then
    reason=""
  else
    [[ ${marker:20:1} == ' ' ]] || return 1
    reason=${marker:21}
  fi
  printf '%s\n' "$reason"
}

write_pinned_marker() {
  local destination_index=$1
  local backup_id=$2
  local reason=$3
  local type source final_object temporary_object

  [[ -n $WORK_DIRECTORY && -d $WORK_DIRECTORY ]] || return 1
  source="$WORK_DIRECTORY/$backup_id.pinned"
  final_object=$(destination_object "$destination_index" "$backup_id.pinned")
  printf '%s' "$(timestamp)" >"$source"
  [[ -z $reason ]] || printf ' %s' "$reason" >>"$source"
  printf '\n' >>"$source"

  type=$(destination_type "$destination_index")
  case "$type" in
    local)
      atomic_copy "$source" "$final_object"
      ;;
    rclone)
      require_command rclone
      temporary_object="${final_object}.partial.$$"
      rclone deletefile "$temporary_object" >/dev/null 2>&1 || true
      if rclone copyto "$source" "$temporary_object" \
        && rclone moveto "$temporary_object" "$final_object"; then
        return 0
      fi
      rclone deletefile "$temporary_object" >/dev/null 2>&1 || true
      return 1
      ;;
    *) return 1 ;;
  esac
}

remove_pinned_marker() {
  local destination_index=$1
  local backup_id=$2
  local type object

  type=$(destination_type "$destination_index")
  object=$(destination_object "$destination_index" "$backup_id.pinned")
  case "$type" in
    local)
      rm -f -- "$object"
      ;;
    rclone)
      require_command rclone
      rclone deletefile "$object"
      ;;
    *) return 1 ;;
  esac
}

destination_metadata_value() {
  local destination_index=$1
  local backup_id=$2
  local expression=$3
  local type object
  type=$(destination_type "$destination_index")
  object=$(destination_object "$destination_index" "$backup_id.metadata.json")
  case "$type" in
    local)
      metadata_value "$object" "$expression"
      ;;
    rclone)
      require_command rclone
      rclone cat "$object" | yq eval -r "$expression" -
      ;;
    *) return 1 ;;
  esac
}

backup_uses_minisign() {
  local destination_index=$1
  local backup_id=$2
  local job recorded_method configured_method

  job=$(destination_metadata_value "$destination_index" "$backup_id" '.job // ""') || return 1
  validate_identifier backup_job "$job"
  recorded_method=$(destination_metadata_value "$destination_index" "$backup_id" '.signing.method // "none"') || return 1
  configured_method=$(job_signing_method "$job") || return 1
  [[ $recorded_method == "$configured_method" ]] || return 1
  [[ $recorded_method == minisign ]]
}

validate_backup_bundle() {
  local destination_index=$1
  local backup_id=$2
  local payload metadata_id marker_id job

  validate_identifier backup_id "$backup_id"
  destination_object_exists "$destination_index" "$backup_id.complete" || return 1
  destination_object_exists "$destination_index" "$backup_id.metadata.json" || return 1
  destination_object_exists "$destination_index" "$backup_id.sha256" || return 1
  marker_id=$(destination_marker_value "$destination_index" "$backup_id") || return 1
  [[ $marker_id == "$backup_id" ]] || return 1
  metadata_id=$(destination_metadata_value "$destination_index" "$backup_id" '.backup_id // ""') || return 1
  [[ $metadata_id == "$backup_id" ]] || return 1
  payload=$(destination_metadata_value "$destination_index" "$backup_id" '.payload_file // ""') || return 1
  [[ $payload == "$backup_id".* && $payload != */* && $payload != *$'\n'* ]] || return 1
  destination_object_exists "$destination_index" "$payload" || return 1
  job=$(destination_metadata_value "$destination_index" "$backup_id" '.job // ""') || return 1
  validate_identifier backup_job "$job"
  if backup_uses_minisign "$destination_index" "$backup_id"; then
    destination_object_exists "$destination_index" "$(signature_filename "$backup_id")" || return 1
  else
    [[ $(destination_metadata_value "$destination_index" "$backup_id" '.signing.method // "none"') == none ]] || return 1
    [[ $(job_signing_method "$job") == none ]] || return 1
  fi
  return 0
}

iterate_destination_backup_ids() {
  local destination_index=$1
  local type destination_path marker object backup_id
  type=$(destination_type "$destination_index")
  case "$type" in
    local)
      destination_path=$(destination_local_path "$destination_index")
      while IFS= read -r -d '' marker; do
        backup_id=$(basename -- "$marker" .complete)
        printf '%s\0' "$backup_id"
      done < <(find "$destination_path" -maxdepth 1 -type f -name '*.complete' -print0 2>/dev/null)
      ;;
    rclone)
      require_command rclone
      while IFS= read -r object; do
        case "$object" in
          *.complete)
            backup_id=${object%.complete}
            printf '%s\0' "$backup_id"
            ;;
        esac
      done < <(rclone lsf --files-only --format p "$(destination_rclone_root "$destination_index")" 2>/dev/null)
      ;;
    *) return 1 ;;
  esac | sort -zr
}

iterate_destination_pinned_ids() {
  local destination_index=$1
  local type destination_path marker object backup_id

  type=$(destination_type "$destination_index")
  case "$type" in
    local)
      destination_path=$(destination_local_path "$destination_index")
      while IFS= read -r -d '' marker; do
        backup_id=$(basename -- "$marker" .pinned)
        printf '%s\0' "$backup_id"
      done < <(find "$destination_path" -maxdepth 1 -type f -name '*.pinned' -print0 2>/dev/null)
      ;;
    rclone)
      require_command rclone
      while IFS= read -r object; do
        case "$object" in
          *.pinned)
            backup_id=${object%.pinned}
            printf '%s\0' "$backup_id"
            ;;
        esac
      done < <(rclone lsf --files-only --format p "$(destination_rclone_root "$destination_index")" 2>/dev/null)
      ;;
    *) return 1 ;;
  esac | sort -zr
}

backup_id_timestamp_seconds() {
  local backup_id=$1
  local expected_job=$2
  local prefix host timestamp_value epoch

  if [[ ! $backup_id =~ ^(.+)_([0-9]{8}T[0-9]{6}Z)_([0-9a-f]{8})$ ]]; then
    return 1
  fi
  prefix=${BASH_REMATCH[1]}
  timestamp_value=${BASH_REMATCH[2]}

  [[ $prefix == *"_$expected_job" ]] || return 1
  host=${prefix%_"$expected_job"}
  [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ $host == "$HOST_ID" ]] || return 1

  epoch=$(date -u -d "${timestamp_value:0:4}-${timestamp_value:4:2}-${timestamp_value:6:2} ${timestamp_value:9:2}:${timestamp_value:11:2}:${timestamp_value:13:2} UTC" +%s 2>/dev/null) \
    || return 1
  [[ $(date -u -d "@$epoch" +'%Y%m%dT%H%M%SZ') == "$timestamp_value" ]] || return 1
  printf '%s\n' "$epoch"
}

utc_date_start_seconds() {
  local value=$1
  local epoch canonical

  [[ $value =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
  epoch=$(date -u -d "$value 00:00:00 UTC" +%s 2>/dev/null) || return 1
  canonical=$(date -u -d "@$epoch" +%F 2>/dev/null) || return 1
  [[ $canonical == "$value" ]] || return 1
  printf '%s\n' "$epoch"
}

watchdog_targets() {
  local job_index job_count

  if [[ -n $SELECTED_JOB ]]; then
    printf '%s\n' "$SELECTED_JOB"
    return 0
  fi

  if [[ $(cfg 'has("watchdog")') == true ]] \
    && [[ $(cfg '.watchdog | has("jobs")') == true ]]; then
    job_count=$(cfg '.watchdog.jobs | length')
    for ((job_index = 0; job_index < job_count; job_index++)); do
      cfg ".watchdog.jobs[$job_index]"
    done
    return 0
  fi

  for ((job_index = 0; job_index < JOB_COUNT; job_index++)); do
    cfg ".jobs[$job_index].name"
  done
}

watchdog_latest_backup() {
  local job=$1
  local now_seconds=$2
  local job_index destination_position destination_count destination_name destination_index
  local backup_id timestamp_seconds latest_id="" latest_timestamp=-1

  job_index=$(find_job_index "$job") || return 1
  destination_count=$(cfg ".jobs[$job_index].destinations | length")
  for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
    destination_name=$(cfg ".jobs[$job_index].destinations[$destination_position]")
    destination_index=$(find_destination_index "$destination_name")
    while IFS= read -r -d '' backup_id; do
      backup_id_belongs_to_current_host_job "$backup_id" "$job" || continue
      if [[ ! $backup_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        printf 'event=watchdog-parse-error job=%s backup_id=%s parse_error=1\n' "$job" "$backup_id" >&2
        continue
      fi
      if ! timestamp_seconds=$(backup_id_timestamp_seconds "$backup_id" "$job"); then
        printf 'event=watchdog-parse-error job=%s backup_id=%s parse_error=1\n' "$job" "$backup_id" >&2
        continue
      fi
      if ((timestamp_seconds > now_seconds)); then
        printf 'event=watchdog-parse-error job=%s backup_id=%s parse_error=1 reason=future-timestamp\n' "$job" "$backup_id" >&2
        continue
      fi
      validate_backup_bundle "$destination_index" "$backup_id" || continue
      [[ $(destination_metadata_value "$destination_index" "$backup_id" '.job // ""') == "$job" ]] || continue
      if ((timestamp_seconds > latest_timestamp)); then
        latest_timestamp=$timestamp_seconds
        latest_id=$backup_id
      fi
    done < <(iterate_destination_backup_ids "$destination_index")
  done

  [[ -n $latest_id ]] || return 1
  printf '%s\t%s\n' "$latest_id" "$latest_timestamp"
}

watchdog_command() {
  local configured_max_age="" max_age_hours max_age_seconds now_seconds
  local job latest_record backup_id backup_seconds age_seconds stale=false

  if [[ $(cfg 'has("watchdog")') == true ]] \
    && [[ $(cfg '.watchdog | has("max_age_hours")') == true ]]; then
    configured_max_age=$(cfg '.watchdog.max_age_hours')
  fi
  max_age_hours=${WATCHDOG_MAX_AGE_HOURS:-$configured_max_age}
  [[ -n $max_age_hours ]] || config_error "watchdog-max-age-required use=--max-age-or-watchdog.max_age_hours"
  max_age_seconds=$((max_age_hours * 3600))
  now_seconds=$(date -u +%s)

  while IFS= read -r job; do
    if ! latest_record=$(watchdog_latest_backup "$job" "$now_seconds"); then
      printf 'event=watchdog-stale job=%s last_backup=none max_age_seconds=%s\n' "$job" "$max_age_seconds" >&2
      BACKFORT_EVENT_JOB=$job
      BACKFORT_EVENT_ID=''
      BACKFORT_EVENT_AGE=none
      BACKFORT_EVENT_THRESHOLD="${max_age_hours}h"
      BACKFORT_EVENT_STAGE=watchdog
      BACKFORT_EVENT_ERROR='no completed backup found'
      BACKFORT_EVENT_EXTRA=''
      BACKFORT_EVENT_EXIT_CODE=3
      bf_notify watchdog
      stale=true
      continue
    fi
    IFS=$'\t' read -r backup_id backup_seconds <<<"$latest_record"
    age_seconds=$((now_seconds - backup_seconds))
    if ((age_seconds > max_age_seconds)); then
      printf 'event=watchdog-stale job=%s backup_id=%s age_seconds=%s max_age_seconds=%s\n' \
        "$job" "$backup_id" "$age_seconds" "$max_age_seconds" >&2
      BACKFORT_EVENT_JOB=$job
      BACKFORT_EVENT_ID=$backup_id
      BACKFORT_EVENT_AGE="${age_seconds}s"
      BACKFORT_EVENT_THRESHOLD="${max_age_hours}h"
      BACKFORT_EVENT_STAGE=watchdog
      BACKFORT_EVENT_ERROR='latest backup exceeds freshness threshold'
      BACKFORT_EVENT_EXTRA=''
      BACKFORT_EVENT_EXIT_CODE=3
      bf_notify watchdog
      stale=true
      continue
    fi
    printf 'event=watchdog-ok job=%s backup_id=%s age_seconds=%s max_age_seconds=%s\n' \
      "$job" "$backup_id" "$age_seconds" "$max_age_seconds"
  done < <(watchdog_targets)

  [[ $stale == false ]] || return 3
}

list_command() {
  local destination_index destination_name backup_id job created payload pinned pinned_reason
  local first_json=true
  [[ $JSON_OUTPUT == true ]] && printf '[\n'

  for ((destination_index = 0; destination_index < DESTINATION_COUNT; destination_index++)); do
    destination_name=$(cfg ".destinations[$destination_index].name")
    while IFS= read -r -d '' backup_id; do
      backup_id_belongs_to_current_host "$backup_id" || continue
      validate_identifier backup_id "$backup_id"
      if ! validate_backup_bundle "$destination_index" "$backup_id"; then
        log warning "kind=bundle destination=$destination_name backup_id=$backup_id message=incomplete-or-invalid"
        continue
      fi
      job=$(destination_metadata_value "$destination_index" "$backup_id" '.job // ""')
      [[ -z $SELECTED_JOB || $job == "$SELECTED_JOB" ]] || continue
      created=$(destination_metadata_value "$destination_index" "$backup_id" '.created_at // ""')
      payload=$(destination_metadata_value "$destination_index" "$backup_id" '.payload_file // ""')
      pinned=false
      pinned_reason=""
      if backup_is_pinned "$destination_index" "$backup_id"; then
        pinned=true
        pinned_reason=$(pinned_marker_reason "$destination_index" "$backup_id") || pinned_reason=""
      fi

      if [[ $JSON_OUTPUT == true ]]; then
        [[ $first_json == true ]] || printf ',\n'
        if [[ $(destination_type "$destination_index") == local ]]; then
          BF_LIST_DESTINATION=$destination_name BF_LIST_PINNED=$pinned BF_LIST_PINNED_REASON=$pinned_reason \
            yq eval -o=json -I=2 '. + {
              "destination": strenv(BF_LIST_DESTINATION),
              "pinned": (strenv(BF_LIST_PINNED) == "true"),
              "pinned_reason": strenv(BF_LIST_PINNED_REASON)
            } | with_entries(select(.key != "pinned_reason" or .value != ""))' "$(destination_object "$destination_index" "$backup_id.metadata.json")"
        else
          rclone cat "$(destination_object "$destination_index" "$backup_id.metadata.json")" \
            | BF_LIST_DESTINATION=$destination_name BF_LIST_PINNED=$pinned BF_LIST_PINNED_REASON=$pinned_reason \
              yq eval -o=json -I=2 '. + {
                "destination": strenv(BF_LIST_DESTINATION),
                "pinned": (strenv(BF_LIST_PINNED) == "true"),
                "pinned_reason": strenv(BF_LIST_PINNED_REASON)
              } | with_entries(select(.key != "pinned_reason" or .value != ""))' -
        fi
        first_json=false
      else
        if [[ $pinned == true ]]; then
          if [[ -n $pinned_reason ]]; then
            printf '%s\t%s\t%s\t%s\t%s\tpinned: %s\n' \
              "$created" "$job" "$destination_name" "$backup_id" "$payload" "$pinned_reason"
          else
            printf '%s\t%s\t%s\t%s\t%s\tpinned\n' \
              "$created" "$job" "$destination_name" "$backup_id" "$payload"
          fi
        else
          printf '%s\t%s\t%s\t%s\t%s\n' "$created" "$job" "$destination_name" "$backup_id" "$payload"
        fi
      fi
    done < <(iterate_destination_backup_ids "$destination_index")
  done

  [[ $JSON_OUTPUT == true ]] && printf '\n]\n'
  return 0
}

status_command() {
  local job_index job destination_position destination_count destination_name destination_index
  local backup_id created found
  printf 'JOB\tDESTINATION\tLATEST\tBACKUP_ID\n'

  for ((job_index = 0; job_index < JOB_COUNT; job_index++)); do
    job=$(cfg ".jobs[$job_index].name")
    [[ -z $SELECTED_JOB || $job == "$SELECTED_JOB" ]] || continue
    destination_count=$(cfg ".jobs[$job_index].destinations | length")
    for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
      destination_name=$(cfg ".jobs[$job_index].destinations[$destination_position]")
      destination_index=$(find_destination_index "$destination_name")
      found=false
      while IFS= read -r -d '' backup_id; do
        backup_id_belongs_to_current_host_job "$backup_id" "$job" || continue
        validate_identifier backup_id "$backup_id"
        validate_backup_bundle "$destination_index" "$backup_id" || continue
        [[ $(destination_metadata_value "$destination_index" "$backup_id" '.job // ""') == "$job" ]] || continue
        created=$(destination_metadata_value "$destination_index" "$backup_id" '.created_at // ""')
        printf '%s\t%s\t%s\t%s\n' "$job" "$destination_name" "$created" "$backup_id"
        found=true
        break
      done < <(iterate_destination_backup_ids "$destination_index")
      [[ $found == true ]] || printf '%s\t%s\t%s\t%s\n' "$job" "$destination_name" 'never' '-'
    done
  done
}

BACKUP_DESTINATION_NAME=""
BACKUP_DESTINATION_INDEX=""
BACKUP_ID=""
BACKUP_METADATA=""
BACKUP_CHECKSUM=""
BACKUP_PAYLOAD=""
BACKUP_SIGNATURE=""

selected_metadata_value() {
  local expression=$1
  if [[ -n $BACKUP_METADATA ]]; then
    metadata_value "$BACKUP_METADATA" "$expression"
  else
    destination_metadata_value "$BACKUP_DESTINATION_INDEX" "$BACKUP_ID" "$expression"
  fi
}

set_selected_backup() {
  local destination_index=$1
  local backup_id=$2
  local destination_name payload_name

  destination_name=$(cfg ".destinations[$destination_index].name")
  payload_name=$(destination_metadata_value "$destination_index" "$backup_id" '.payload_file // ""') || return 1
  [[ $payload_name == "$backup_id".* && $payload_name != */* && $payload_name != *$'\n'* ]] || return 1

  BACKUP_DESTINATION_NAME=$destination_name
  BACKUP_DESTINATION_INDEX=$destination_index
  BACKUP_ID=$backup_id
  if [[ $(destination_type "$destination_index") == local ]]; then
    BACKUP_METADATA=$(destination_object "$destination_index" "$backup_id.metadata.json")
    BACKUP_CHECKSUM=$(destination_object "$destination_index" "$backup_id.sha256")
    BACKUP_PAYLOAD=$(destination_object "$destination_index" "$payload_name")
    if backup_uses_minisign "$destination_index" "$backup_id"; then
      BACKUP_SIGNATURE=$(destination_object "$destination_index" "$(signature_filename "$backup_id")")
    else
      BACKUP_SIGNATURE=""
    fi
  else
    BACKUP_METADATA=""
    BACKUP_CHECKSUM=$(destination_object "$destination_index" "$backup_id.sha256")
    BACKUP_PAYLOAD=$(destination_object "$destination_index" "$payload_name")
    BACKUP_SIGNATURE=""
  fi
}

select_backup() {
  local reference=$1
  local destination_index destination_name backup_id job created
  local chosen_created="" chosen_id="" chosen_index=""

  if [[ $reference != latest ]]; then
    validate_identifier backup_id "$reference"
  elif [[ -z $SELECTED_JOB ]]; then
    config_error "latest-requires-job-selection"
  fi

  for ((destination_index = 0; destination_index < DESTINATION_COUNT; destination_index++)); do
    destination_name=$(cfg ".destinations[$destination_index].name")
    [[ -z $SELECTED_DESTINATION || $destination_name == "$SELECTED_DESTINATION" ]] || continue

    if [[ $reference != latest ]]; then
      if validate_backup_bundle "$destination_index" "$reference"; then
        if [[ -n $SELECTED_JOB ]]; then
          [[ $(destination_metadata_value "$destination_index" "$reference" '.job // ""') == "$SELECTED_JOB" ]] || continue
        fi
        chosen_id=$reference
        chosen_index=$destination_index
        break
      fi
      continue
    fi

    while IFS= read -r -d '' backup_id; do
      backup_id_belongs_to_current_host_job "$backup_id" "$SELECTED_JOB" || continue
      validate_identifier backup_id "$backup_id"
      validate_backup_bundle "$destination_index" "$backup_id" || continue
      job=$(destination_metadata_value "$destination_index" "$backup_id" '.job // ""')
      [[ $job == "$SELECTED_JOB" ]] || continue
      created=$(destination_metadata_value "$destination_index" "$backup_id" '.created_at // ""')
      if [[ -z $chosen_created || $created > $chosen_created ]]; then
        chosen_created=$created
        chosen_id=$backup_id
        chosen_index=$destination_index
      fi
    done < <(iterate_destination_backup_ids "$destination_index")
  done

  if [[ -z $chosen_id ]]; then
    log error "kind=lookup message=backup-not-found reference=$reference"
    return 3
  fi

  set_selected_backup "$chosen_index" "$chosen_id" || return 1
}

bf_is_interactive() {
  # Internal test hook: production invocations require real stdin and stdout
  # terminals, while tests feed a scripted answer through stdin.
  [[ ${BACKFORT_TEST_ASSUME_TTY:-} == 1 ]] && return 0
  [[ -t 0 && -t 1 ]]
}

destination_payload_size_bytes() {
  local destination_index=$1
  local payload_name=$2
  local type object bytes

  type=$(destination_type "$destination_index")
  object=$(destination_object "$destination_index" "$payload_name")
  case "$type" in
    local)
      stat --format='%s' "$object"
      ;;
    rclone)
      require_command rclone
      bytes=$(rclone lsf --files-only --format s "$object") || return 1
      [[ $bytes =~ ^[0-9]+$ ]] || return 1
      printf '%s\n' "$bytes"
      ;;
    *) return 1 ;;
  esac
}

format_restore_pick_size() {
  local bytes=$1

  awk -v bytes="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", units, " ")
    value = bytes
    unit = 1
    while (value >= 1024 && unit < 5) {
      value /= 1024
      unit++
    }
    if (unit == 1) {
      printf "%d %s", value, units[unit]
    } else {
      printf "%.1f %s", value, units[unit]
    }
  }'
}

format_restore_pick_age() {
  local backup_seconds=$1
  local now_seconds=$2
  local age_seconds weeks days hours minutes

  age_seconds=$((now_seconds - backup_seconds))
  ((age_seconds >= 0)) || age_seconds=0
  if ((age_seconds >= 2592000)); then
    date -u -d "@$backup_seconds" +'%Y-%m-%d'
    return 0
  fi
  if ((age_seconds >= 604800)); then
    weeks=$((age_seconds / 604800))
    days=$(((age_seconds % 604800) / 86400))
    if ((days > 0)); then
      printf '%sw %sd ago\n' "$weeks" "$days"
    else
      printf '%sw ago\n' "$weeks"
    fi
    return 0
  fi
  if ((age_seconds >= 86400)); then
    days=$((age_seconds / 86400))
    hours=$(((age_seconds % 86400) / 3600))
    if ((hours > 0)); then
      printf '%sd %sh ago\n' "$days" "$hours"
    else
      printf '%sd ago\n' "$days"
    fi
    return 0
  fi
  hours=$((age_seconds / 3600))
  minutes=$(((age_seconds % 3600) / 60))
  if ((hours > 0)); then
    printf '%sh%sm ago\n' "$hours" "$minutes"
  else
    printf '%sm ago\n' "$minutes"
  fi
}

restore_pick_command() {
  local job_index job destination_count destination_position destination_name destination_index
  local backup_id metadata_job payload_name backup_seconds payload_size now_seconds
  local record index age size response selection
  local -a unsorted=() records=() backup_ids=() destination_names=()
  # Keep the retry limit constant so a noninteractive mistake cannot turn into
  # an unbounded read loop.
  local -r maximum_attempts=3
  local attempt

  RESTORE_PICK_CANCELLED=false
  if ! bf_is_interactive; then
    printf '%s\n' '--pick requires an interactive terminal; pass a backup ID instead' >&2
    return 2
  fi
  if [[ -z $SELECTED_JOB ]]; then
    if ((JOB_COUNT != 1)); then
      printf '%s\n' 'restore --pick requires --job when config has multiple jobs' >&2
      return 2
    fi
    SELECTED_JOB=$(cfg '.jobs[0].name')
  fi
  job_index=$(find_job_index "$SELECTED_JOB") || return 2
  job=$SELECTED_JOB

  require_command date
  require_command sort
  require_command stat
  require_command awk
  now_seconds=$(date -u +%s)
  destination_count=$(cfg ".jobs[$job_index].destinations | length")
  for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
    destination_name=$(cfg ".jobs[$job_index].destinations[$destination_position]")
    [[ -z $SELECTED_DESTINATION || $destination_name == "$SELECTED_DESTINATION" ]] || continue
    destination_index=$(find_destination_index "$destination_name")
    while IFS= read -r -d '' backup_id; do
      backup_id_belongs_to_current_host_job "$backup_id" "$job" || continue
      validate_backup_bundle "$destination_index" "$backup_id" || continue
      metadata_job=$(destination_metadata_value "$destination_index" "$backup_id" '.job // ""') || continue
      [[ $metadata_job == "$job" ]] || continue
      if ! backup_seconds=$(backup_id_timestamp_seconds "$backup_id" "$job"); then
        log warning "kind=restore-pick job=$job destination=$destination_name backup_id=$backup_id message=invalid-backup-timestamp"
        continue
      fi
      payload_name=$(destination_metadata_value "$destination_index" "$backup_id" '.payload_file // ""') || return 3
      if ! payload_size=$(destination_payload_size_bytes "$destination_index" "$payload_name"); then
        log error "kind=restore-pick job=$job destination=$destination_name backup_id=$backup_id message=payload-size-unavailable"
        return 3
      fi
      [[ $payload_size =~ ^[0-9]+$ ]] || return 3
      unsorted+=("$backup_seconds|$backup_id|$destination_index|$destination_name|$payload_size")
    done < <(iterate_destination_backup_ids "$destination_index")
  done

  if ((${#unsorted[@]} == 0)); then
    printf 'no completed backups for job %s\n' "$job" >&2
    return 3
  fi
  mapfile -t records < <(printf '%s\n' "${unsorted[@]+"${unsorted[@]}"}" | sort -t '|' -k1,1nr -k2,2r -k4,4)

  printf '%-3s %-52s %-12s %-10s %s\n' '#' 'backup_id' 'age' 'size' 'destination'
  for ((index = 0; index < ${#records[@]}; index++)); do
    IFS='|' read -r backup_seconds backup_id destination_index destination_name payload_size <<<"${records[$index]}"
    age=$(format_restore_pick_age "$backup_seconds" "$now_seconds")
    size=$(format_restore_pick_size "$payload_size")
    printf '%-3s %-52s %-12s %-10s %s\n' \
      "$((index + 1))" "$backup_id" "$age" "$size" "$destination_name"
    backup_ids[index]=$backup_id
    destination_names[index]=$destination_name
  done

  for ((attempt = 1; attempt <= maximum_attempts; attempt++)); do
    printf 'Restore #> '
    if [[ ${BACKFORT_TEST_ASSUME_TTY:-} == 1 ]]; then
      if ! IFS= read -r response; then
        response=""
      fi
    elif ! IFS= read -r response </dev/tty; then
      response=""
    fi
    case "$response" in
      ''|q)
        RESTORE_PICK_CANCELLED=true
        printf 'restore cancelled\n'
        return 0
        ;;
      *[!0-9]*|??????????*)
        printf 'invalid selection\n' >&2
        continue
        ;;
      *)
        selection=$((10#$response))
        if ((selection >= 1 && selection <= ${#backup_ids[@]})); then
          BACKUP_REFERENCE=${backup_ids[selection - 1]}
          SELECTED_DESTINATION=${destination_names[selection - 1]}
          printf 'selected=%s to=%s\n' "$BACKUP_REFERENCE" "$RESTORE_DIRECTORY"
          return 0
        fi
        printf 'invalid selection\n' >&2
        ;;
    esac
  done

  RESTORE_PICK_CANCELLED=true
  printf 'restore cancelled\n' >&2
  return 2
}

materialize_selected_backup() {
  local type payload_name signing_method
  type=$(destination_type "$BACKUP_DESTINATION_INDEX")
  [[ $type == rclone ]] || return 0
  require_command rclone
  [[ -n $WORK_DIRECTORY && -d $WORK_DIRECTORY ]] || return 3

  BACKUP_METADATA="$WORK_DIRECTORY/$BACKUP_ID.metadata.json"
  BACKUP_CHECKSUM="$WORK_DIRECTORY/$BACKUP_ID.sha256"
  if ! rclone copyto "$(destination_object "$BACKUP_DESTINATION_INDEX" "$BACKUP_ID.metadata.json")" "$BACKUP_METADATA"; then
    log error "kind=download backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME message=metadata-download-failed"
    return 3
  fi
  payload_name=$(metadata_value "$BACKUP_METADATA" '.payload_file // ""')
  if [[ $payload_name != "$BACKUP_ID".* || $payload_name == */* || $payload_name == *$'\n'* ]]; then
    log error "kind=download backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME message=invalid-payload-name"
    return 3
  fi
  BACKUP_PAYLOAD="$WORK_DIRECTORY/$payload_name"
  if ! rclone copyto "$(destination_object "$BACKUP_DESTINATION_INDEX" "$BACKUP_ID.sha256")" "$BACKUP_CHECKSUM" \
    || ! rclone copyto "$(destination_object "$BACKUP_DESTINATION_INDEX" "$payload_name")" "$BACKUP_PAYLOAD"; then
    log error "kind=download backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME message=bundle-download-failed"
    return 3
  fi
  signing_method=$(metadata_value "$BACKUP_METADATA" '.signing.method // "none"')
  if [[ $signing_method == minisign ]]; then
    BACKUP_SIGNATURE="$WORK_DIRECTORY/$(signature_filename "$BACKUP_ID")"
    if ! rclone copyto "$(destination_object "$BACKUP_DESTINATION_INDEX" "$(signature_filename "$BACKUP_ID")")" "$BACKUP_SIGNATURE"; then
      log error "kind=download backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME message=signature-download-failed"
      return 3
    fi
  else
    BACKUP_SIGNATURE=""
  fi
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

verify_signature() {
  local job signing_method public_key_env public_key

  job=$(metadata_value "$BACKUP_METADATA" '.job // ""')
  validate_identifier backup_job "$job"
  signing_method=$(job_signing_method "$job") || return 3
  [[ $signing_method == minisign ]] || return 0
  [[ -n $BACKUP_SIGNATURE && -f $BACKUP_SIGNATURE && ! -L $BACKUP_SIGNATURE ]] || {
    log error "kind=verify backup_id=$BACKUP_ID message=signature-missing"
    return 3
  }
  require_command minisign
  public_key_env=$(job_signing_public_key_env "$job") || return 3
  public_key=${!public_key_env-}
  [[ -n $public_key ]] || config_error "missing-environment-variable variable=$public_key_env"
  if ! minisign -V -q -P "$public_key" -m "$BACKUP_PAYLOAD" -x "$BACKUP_SIGNATURE"; then
    public_key=""
    log error "kind=verify backup_id=$BACKUP_ID message=signature-invalid"
    return 3
  fi
  public_key=""
}

ensure_selected_archive_streamable() {
  local encryption compression env_name identity_file password_env identity_password_env secret

  if [[ $(destination_type "$BACKUP_DESTINATION_INDEX") == rclone ]]; then
    require_command rclone
  fi
  encryption=$(selected_metadata_value '.encryption.method // "none"') || return 3
  compression=$(selected_metadata_value '.compression.method // "gzip"') || return 3
  case "$encryption" in
    none) : ;;
    age)
      require_command age
      env_name=$(selected_metadata_value '.encryption.identity_file_env // ""') || return 3
      [[ -n $env_name ]] || config_error "age-identity-file-env-not-recorded backup_id=$BACKUP_ID"
      validate_env_name encryption.identity_file_env "$env_name"
      identity_file=${!env_name-}
      [[ -n $identity_file && -r $identity_file ]] || config_error "age-identity-file-not-readable variable=$env_name"
      ;;
    gpg)
      require_command gpg
      password_env=$(selected_metadata_value '.encryption.password_env // ""') || return 3
      if [[ -n $password_env ]]; then
        validate_env_name encryption.password_env "$password_env"
        secret=${!password_env-}
        [[ -n $secret ]] || config_error "missing-environment-variable variable=$password_env"
        secret=""
      else
        identity_password_env=$(selected_metadata_value '.encryption.identity_password_env // ""') || return 3
        if [[ -n $identity_password_env ]]; then
          validate_env_name encryption.identity_password_env "$identity_password_env"
          secret=${!identity_password_env-}
          [[ -n $secret ]] || config_error "missing-environment-variable variable=$identity_password_env"
          secret=""
        fi
      fi
      ;;
    *)
      log error "kind=archive backup_id=$BACKUP_ID message=unknown-encryption-method"
      return 3
      ;;
  esac
  case "$compression" in
    gzip) require_command gzip ;;
    zstd) require_command zstd ;;
    none) : ;;
    *)
      log error "kind=archive backup_id=$BACKUP_ID message=unknown-compression-method"
      return 3
      ;;
  esac
}

stream_selected_payload() {
  # Remote bundles are materialized locally before checksum/signature checks.
  # Stream that verified artifact instead of passing its temporary local path to
  # rclone, which expects a remote object name.
  if [[ -f $BACKUP_PAYLOAD && ! -L $BACKUP_PAYLOAD ]]; then
    cat -- "$BACKUP_PAYLOAD"
    return 0
  fi

  case "$(destination_type "$BACKUP_DESTINATION_INDEX")" in
    rclone)
      require_command rclone
      rclone cat "$BACKUP_PAYLOAD"
      ;;
    *) return 3 ;;
  esac
}

stream_selected_decrypted_payload() {
  local encryption env_name identity_file password_env identity_password_env secret
  encryption=$(selected_metadata_value '.encryption.method // "none"') || return 3
  case "$encryption" in
    none) stream_selected_payload ;;
    age)
      env_name=$(selected_metadata_value '.encryption.identity_file_env // ""') || return 3
      identity_file=${!env_name-}
      stream_selected_payload | age --decrypt --identity "$identity_file"
      ;;
    gpg)
      password_env=$(selected_metadata_value '.encryption.password_env // ""') || return 3
      if [[ -n $password_env ]]; then
        secret=${!password_env-}
        stream_selected_payload | gpg --batch --yes --no-tty --no-auto-key-retrieve \
          --pinentry-mode loopback --passphrase-fd 3 --decrypt 3< <(printf '%s' "$secret")
        secret=""
      else
        identity_password_env=$(selected_metadata_value '.encryption.identity_password_env // ""') || return 3
        if [[ -n $identity_password_env ]]; then
          secret=${!identity_password_env-}
          stream_selected_payload | gpg --batch --yes --no-tty --no-auto-key-retrieve \
            --pinentry-mode loopback --passphrase-fd 3 --decrypt 3< <(printf '%s' "$secret")
          secret=""
        else
          stream_selected_payload | gpg --batch --yes --no-tty --no-auto-key-retrieve --decrypt
        fi
      fi
      ;;
    *) return 3 ;;
  esac
}

stream_selected_archive() {
  local compression
  compression=$(selected_metadata_value '.compression.method // "gzip"') || return 3
  case "$compression" in
    gzip) stream_selected_decrypted_payload | gzip -dc ;;
    zstd) stream_selected_decrypted_payload | zstd -q -dc ;;
    none) stream_selected_decrypted_payload ;;
    *) return 3 ;;
  esac
}

verify_manifest_file_hashes() {
  local tar_file=$1
  local manifest=$2
  local algorithm expected_records actual_records
  local entry_path entry_type expected_hash extra
  local hash_record actual_hash actual_archive_path

  algorithm=$(metadata_value "$manifest" '.file_hash_algorithm // ""') || return 3
  case "$algorithm" in
    '') return 0 ;;
    sha256) : ;;
    *)
      log error "kind=verify backup_id=$BACKUP_ID message=unsupported-file-hash-algorithm"
      return 3
      ;;
  esac
  if [[ $(metadata_value "$manifest" '.entries | type') != '!!seq' ]]; then
    log error "kind=verify backup_id=$BACKUP_ID message=file-hash-entries-missing"
    return 3
  fi

  expected_records="$WORK_DIRECTORY/manifest-file-hashes.tsv"
  actual_records="$WORK_DIRECTORY/archive-file-hashes.nul"
  if ! yq eval -o=tsv '.entries | map([.path, .type, (.sha256 // "")])' "$manifest" >"$expected_records" \
    || ! hash_regular_archive_files "$tar_file" "$actual_records"; then
    log error "kind=verify backup_id=$BACKUP_ID message=file-hash-read-failed"
    return 3
  fi

  exec 3<"$actual_records"
  while IFS=$'\t' read -r entry_path entry_type expected_hash extra; do
    if [[ -n ${extra:-} ]] || ! safe_manifest_entry_path "$entry_path"; then
      exec 3<&-
      log error "kind=verify backup_id=$BACKUP_ID message=file-hash-manifest-invalid"
      return 3
    fi
    case "$entry_type" in
      file)
        if [[ ! $expected_hash =~ ^[a-f0-9]{64}$ ]] \
          || ! IFS= read -r -d '' hash_record <&3 \
          || [[ $hash_record != *$'\t'* ]]; then
          exec 3<&-
          log error "kind=verify backup_id=$BACKUP_ID message=file-hash-manifest-invalid"
          return 3
        fi
        actual_hash=${hash_record%%$'\t'*}
        actual_archive_path=${hash_record#*$'\t'}
        if [[ ! $actual_hash =~ ^[a-f0-9]{64}$ \
          || $actual_archive_path != "data/$entry_path" \
          || $actual_hash != "$expected_hash" ]]; then
          exec 3<&-
          log error "kind=verify backup_id=$BACKUP_ID message=file-hash-mismatch"
          return 3
        fi
        ;;
      directory|symlink|hardlink)
        if [[ -n $expected_hash ]]; then
          exec 3<&-
          log error "kind=verify backup_id=$BACKUP_ID message=file-hash-manifest-invalid"
          return 3
        fi
        ;;
      *)
        exec 3<&-
        log error "kind=verify backup_id=$BACKUP_ID message=file-hash-manifest-invalid"
        return 3
        ;;
    esac
  done <"$expected_records"

  if IFS= read -r -d '' <&3; then
    exec 3<&-
    log error "kind=verify backup_id=$BACKUP_ID message=file-hash-manifest-invalid"
    return 3
  fi
  exec 3<&-
}

prepare_tar() {
  local tar_file entries verbose_entries internal_manifest
  tar_file="$WORK_DIRECTORY/backup.tar"
  entries="$WORK_DIRECTORY/archive.entries"
  verbose_entries="$WORK_DIRECTORY/archive.verbose"
  internal_manifest="$WORK_DIRECTORY/internal-manifest.json"

  ensure_selected_archive_streamable || return 3
  if ! stream_selected_archive >"$tar_file"; then
    log error "kind=verify backup_id=$BACKUP_ID message=archive-stream-failed"
    return 3
  fi

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
  verify_manifest_file_hashes "$tar_file" "$internal_manifest"
}

find_completed_backup_destination() {
  local backup_id=$1
  local destination_index

  for ((destination_index = 0; destination_index < DESTINATION_COUNT; destination_index++)); do
    if validate_backup_bundle "$destination_index" "$backup_id"; then
      printf '%s\n' "$destination_index"
      return 0
    fi
  done
  return 1
}

require_diff_bundle() {
  local destination_index=$1
  local backup_id=$2
  local destination_name

  destination_name=$(cfg ".destinations[$destination_index].name")
  if ! validate_backup_bundle "$destination_index" "$backup_id"; then
    log error "kind=diff message=backup-not-available backup_id=$backup_id destination=$destination_name"
    return 1
  fi
}

select_diff_backups() {
  local id_one=$1
  local id_two=$2
  local destination_index job_index job_one job_two destination_name

  validate_identifier diff_id_one "$id_one"
  validate_identifier diff_id_two "$id_two"

  if [[ -n $SELECTED_DESTINATION ]]; then
    destination_index=$(find_destination_index "$SELECTED_DESTINATION")
  else
    if ! destination_index=$(find_completed_backup_destination "$id_one"); then
      log error "kind=diff message=backup-not-found backup_id=$id_one"
      return 1
    fi
  fi

  require_diff_bundle "$destination_index" "$id_one" || return 1
  job_one=$(destination_metadata_value "$destination_index" "$id_one" '.job // ""') || return 1
  validate_identifier diff_job "$job_one"
  job_index=$(find_job_index "$job_one") || return 1

  if [[ -z $SELECTED_DESTINATION ]]; then
    destination_name=$(cfg ".jobs[$job_index].destinations[0]")
    destination_index=$(find_destination_index "$destination_name")
    require_diff_bundle "$destination_index" "$id_one" || return 1
  fi

  require_diff_bundle "$destination_index" "$id_two" || return 1
  job_two=$(destination_metadata_value "$destination_index" "$id_two" '.job // ""') || return 1
  validate_identifier diff_job "$job_two"
  if [[ $job_one != "$job_two" ]]; then
    log error "kind=diff message=jobs-do-not-match id1=$id_one job1=$job_one id2=$id_two job2=$job_two"
    return 1
  fi

  printf '%s\t%s\n' "$destination_index" "$job_one"
}

extract_selected_manifest() {
  local output=$1
  local expected_job=$2

  ensure_selected_archive_streamable || return 3
  if ! stream_selected_archive | tar --extract --to-stdout --file - manifest.json >"$output"; then
    log error "kind=diff backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME message=manifest-extract-failed"
    return 3
  fi
  if ! yq eval '.' "$output" >/dev/null 2>&1; then
    log error "kind=diff backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME message=invalid-manifest"
    return 2
  fi
  if [[ $(metadata_value "$output" '.backup_id // ""') != "$BACKUP_ID" \
    || $(metadata_value "$output" '.job // ""') != "$expected_job" ]]; then
    log error "kind=diff backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME message=manifest-identity-mismatch"
    return 2
  fi
  if [[ $(metadata_value "$output" '.entries | type') != '!!seq' ]]; then
    log error "kind=diff backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME message=manifest-entries-missing"
    return 2
  fi
}

manifest_to_diff_index() {
  local manifest=$1
  local output=$2
  local raw="$output.raw"
  local path entry_type size mtime target extra previous_path=""

  if ! yq eval -o=tsv '.entries | map([.path, .type, .size, .mtime, (.target // "")])' "$manifest" >"$raw"; then
    log error "kind=diff message=manifest-entries-invalid"
    return 2
  fi
  while IFS=$'\t' read -r path entry_type size mtime target extra; do
    [[ -z ${extra:-} ]] || return 2
    safe_manifest_entry_path "$path" || return 2
    case "$entry_type" in
      file|directory|symlink|hardlink) : ;;
      *) return 2 ;;
    esac
    [[ $size =~ ^[0-9]+$ && -n $mtime && $mtime != *$'\n'* && $mtime != *$'\r'* && $mtime != *$'\t'* ]] || return 2
    [[ $target != *$'\n'* && $target != *$'\r'* && $target != *$'\t'* \
      && $target != __BACKFORT_MISSING_FIELD__ ]] || return 2
  done <"$raw"
  if ! LC_ALL=C sort -t $'\t' -k1,1 "$raw" >"$output"; then
    return 3
  fi
  while IFS=$'\t' read -r path entry_type size mtime target; do
    if [[ -n $previous_path && $path == "$previous_path" ]]; then
      return 2
    fi
    previous_path=$path
  done <"$output"
}

classify_diff_records() {
  local index_one=$1
  local index_two=$2
  local added=$3
  local removed=$4
  local modified=$5
  local joined="$WORK_DIRECTORY/diff-joined.tsv"
  local path type_one size_one mtime_one target_one type_two size_two mtime_two target_two
  local missing_field='__BACKFORT_MISSING_FIELD__'

  : >"$added"
  : >"$removed"
  : >"$modified"
  if ! join -t $'\t' -a 1 -a 2 -e "$missing_field" -o '0,1.2,1.3,1.4,1.5,2.2,2.3,2.4,2.5' \
    "$index_one" "$index_two" >"$joined"; then
    return 3
  fi
  while IFS=$'\t' read -r path type_one size_one mtime_one target_one type_two size_two mtime_two target_two; do
    [[ $type_one != "$missing_field" ]] || type_one=""
    [[ $size_one != "$missing_field" ]] || size_one=""
    [[ $mtime_one != "$missing_field" ]] || mtime_one=""
    [[ $type_two != "$missing_field" ]] || type_two=""
    [[ $size_two != "$missing_field" ]] || size_two=""
    [[ $mtime_two != "$missing_field" ]] || mtime_two=""
    if [[ -z $type_one ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$type_two" "$size_two" "$mtime_two" "$target_two" >>"$added"
      continue
    fi
    if [[ -z $type_two ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$path" "$type_one" "$size_one" "$mtime_one" "$target_one" >>"$removed"
      continue
    fi
    if [[ $type_one != "$type_two" || $size_one != "$size_two" || $mtime_one != "$mtime_two" ]] \
      || { [[ $type_one == symlink && $target_one != "$missing_field" && $target_two != "$missing_field" && $target_one != "$target_two" ]]; }; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$path" "$type_one" "$size_one" "$mtime_one" "$target_one" "$type_two" "$size_two" "$mtime_two" "$target_two" >>"$modified"
    fi
  done <"$joined"
}

diff_record_count() {
  local file=$1
  local count
  count=$(wc -l <"$file")
  count=${count//[[:space:]]/}
  printf '%s\n' "$count"
}

print_diff_text() {
  local added=$1
  local removed=$2
  local modified=$3
  local added_count=$4
  local removed_count=$5
  local modified_count=$6
  local path entry_type size mtime target type_one size_one mtime_one target_one type_two size_two mtime_two target_two
  local type_changed=0 mtime_changed=0 target_changed=0

  while IFS=$'\t' read -r path entry_type size mtime target; do
    printf 'diff=added path=%s type=%s size=%s\n' "$path" "$entry_type" "$size"
  done <"$added"
  while IFS=$'\t' read -r path entry_type size mtime target; do
    printf 'diff=removed path=%s type=%s size=%s\n' "$path" "$entry_type" "$size"
  done <"$removed"
  while IFS=$'\t' read -r path type_one size_one mtime_one target_one type_two size_two mtime_two target_two; do
    type_changed=0
    mtime_changed=0
    target_changed=0
    [[ $type_one == "$type_two" ]] || type_changed=1
    [[ $mtime_one == "$mtime_two" ]] || mtime_changed=1
    [[ $target_one == __BACKFORT_MISSING_FIELD__ || $target_two == __BACKFORT_MISSING_FIELD__ \
      || $target_one == "$target_two" ]] || target_changed=1
    printf 'diff=modified path=%s type=%s:%s size=%s:%s mtime_changed=%s type_changed=%s target_changed=%s\n' \
      "$path" "$type_one" "$type_two" "$size_one" "$size_two" "$mtime_changed" "$type_changed" "$target_changed"
  done <"$modified"
  printf 'added=%s removed=%s modified=%s\n' "$added_count" "$removed_count" "$modified_count"
}

write_diff_json_entries() {
  local key=$1
  local records_file=$2
  local kind=$3
  local path entry_type size mtime target type_one size_one mtime_one target_one type_two size_two mtime_two target_two
  local type_changed mtime_changed target_changed

  if [[ ! -s $records_file ]]; then
    printf '%s: []\n' "$key"
    return 0
  fi
  printf '%s:\n' "$key"
  if [[ $kind == modified ]]; then
    while IFS=$'\t' read -r path type_one size_one mtime_one target_one type_two size_two mtime_two target_two; do
      type_changed=false
      mtime_changed=false
      target_changed=false
      [[ $type_one == "$type_two" ]] || type_changed=true
      [[ $mtime_one == "$mtime_two" ]] || mtime_changed=true
      [[ $target_one == __BACKFORT_MISSING_FIELD__ || $target_two == __BACKFORT_MISSING_FIELD__ \
        || $target_one == "$target_two" ]] || target_changed=true
      printf '  - path: %s\n' "$(yaml_quote "$path")"
      printf '    type_before: %s\n' "$(yaml_quote "$type_one")"
      printf '    type_after: %s\n' "$(yaml_quote "$type_two")"
      printf '    size_before: %s\n' "$size_one"
      printf '    size_after: %s\n' "$size_two"
      printf '    mtime_before: %s\n' "$(yaml_quote "$mtime_one")"
      printf '    mtime_after: %s\n' "$(yaml_quote "$mtime_two")"
      printf '    type_changed: %s\n' "$type_changed"
      printf '    mtime_changed: %s\n' "$mtime_changed"
      printf '    target_changed: %s\n' "$target_changed"
    done <"$records_file"
    return 0
  fi
  while IFS=$'\t' read -r path entry_type size mtime target; do
    printf '  - path: %s\n' "$(yaml_quote "$path")"
    printf '    type: %s\n' "$(yaml_quote "$entry_type")"
    printf '    size: %s\n' "$size"
    printf '    mtime: %s\n' "$(yaml_quote "$mtime")"
  done <"$records_file"
}

print_diff_json() {
  local id_one=$1
  local id_two=$2
  local added=$3
  local removed=$4
  local modified=$5
  local added_count=$6
  local removed_count=$7
  local modified_count=$8
  local output="$WORK_DIRECTORY/diff-output.yaml"

  {
    printf 'id1: %s\n' "$(yaml_quote "$id_one")"
    printf 'id2: %s\n' "$(yaml_quote "$id_two")"
    write_diff_json_entries added "$added" added
    write_diff_json_entries removed "$removed" removed
    write_diff_json_entries modified "$modified" modified
    printf 'summary:\n'
    printf '  added: %s\n' "$added_count"
    printf '  removed: %s\n' "$removed_count"
    printf '  modified: %s\n' "$modified_count"
  } >"$output"
  yq eval -o=json "$output"
}

diff_command() {
  local selection destination_index diff_job result
  local manifest_one manifest_two index_one index_two added removed modified
  local added_count removed_count modified_count

  require_command tar
  require_command sort
  require_command join
  if ! selection=$(select_diff_backups "$DIFF_ID_ONE" "$DIFF_ID_TWO"); then
    return 2
  fi
  IFS=$'\t' read -r destination_index diff_job <<<"$selection"

  if ! make_work_directory; then
    return 3
  fi
  manifest_one="$WORK_DIRECTORY/diff-manifest-one.json"
  manifest_two="$WORK_DIRECTORY/diff-manifest-two.json"
  index_one="$WORK_DIRECTORY/diff-index-one.tsv"
  index_two="$WORK_DIRECTORY/diff-index-two.tsv"
  added="$WORK_DIRECTORY/diff-added.tsv"
  removed="$WORK_DIRECTORY/diff-removed.tsv"
  modified="$WORK_DIRECTORY/diff-modified.tsv"
  if ! set_selected_backup "$destination_index" "$DIFF_ID_ONE"; then
    cleanup_work_directory
    return 2
  fi
  if extract_selected_manifest "$manifest_one" "$diff_job"; then
    :
  else
    result=$?
    cleanup_work_directory
    return "$result"
  fi
  if ! set_selected_backup "$destination_index" "$DIFF_ID_TWO"; then
    cleanup_work_directory
    return 2
  fi
  if extract_selected_manifest "$manifest_two" "$diff_job"; then
    :
  else
    result=$?
    cleanup_work_directory
    return "$result"
  fi
  if manifest_to_diff_index "$manifest_one" "$index_one" && manifest_to_diff_index "$manifest_two" "$index_two"; then
    :
  else
    result=$?
    cleanup_work_directory
    return "$result"
  fi
  if ! classify_diff_records "$index_one" "$index_two" "$added" "$removed" "$modified"; then
    cleanup_work_directory
    return 3
  fi

  added_count=$(diff_record_count "$added")
  removed_count=$(diff_record_count "$removed")
  modified_count=$(diff_record_count "$modified")
  if [[ $JSON_OUTPUT == true ]]; then
    if ! print_diff_json "$DIFF_ID_ONE" "$DIFF_ID_TWO" "$added" "$removed" "$modified" \
      "$added_count" "$removed_count" "$modified_count"; then
      cleanup_work_directory
      return 3
    fi
  else
    print_diff_text "$added" "$removed" "$modified" "$added_count" "$removed_count" "$modified_count"
  fi
  cleanup_work_directory
}

verify_command() {
  require_command sha256sum
  require_command awk
  require_command cat
  require_command chmod
  require_command cmp
  require_command find
  require_command flock
  require_command rm
  require_command sort
  require_command tar
  if ! acquire_lock; then
    return 3
  fi
  if ! select_backup "$BACKUP_REFERENCE"; then
    return 3
  fi
  if [[ $(destination_type "$BACKUP_DESTINATION_INDEX") == rclone ]]; then
    if ! make_work_directory; then
      return 3
    fi
    if ! materialize_selected_backup; then
      cleanup_work_directory
      return 3
    fi
  fi
  if ! verify_signature || ! verify_checksum; then
    cleanup_work_directory
    return 3
  fi
  if [[ $VERIFY_MODE == full ]]; then
    if [[ -z $WORK_DIRECTORY ]] && ! make_work_directory; then
      return 3
    fi
    if ! prepare_tar; then
      cleanup_work_directory
      return 3
    fi
  fi
  cleanup_work_directory
  log info "event=verify-succeeded backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME mode=$VERIFY_MODE"
}

restore_command() {
  local pick_result
  if [[ $RESTORE_PICK == true ]]; then
    if restore_pick_command; then
      :
    else
      pick_result=$?
      return "$pick_result"
    fi
    [[ $RESTORE_PICK_CANCELLED == false ]] || return 0
  fi
  validate_absolute_path restore.to "$RESTORE_DIRECTORY"
  require_command sha256sum
  require_command awk
  require_command cat
  require_command chmod
  require_command cmp
  require_command find
  require_command rm
  require_command sort
  require_command tar

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
  if [[ $(destination_type "$BACKUP_DESTINATION_INDEX") == rclone ]]; then
    if ! make_work_directory; then
      return 3
    fi
    if ! materialize_selected_backup; then
      cleanup_work_directory
      return 3
    fi
  fi
  if ! verify_signature || ! verify_checksum; then
    cleanup_work_directory
    return 3
  fi
  if [[ -z $WORK_DIRECTORY ]] && ! make_work_directory; then
    return 3
  fi
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

compose_restore_prepare() {
  local backup_job backup_source job_index

  if ! select_backup "$BACKUP_REFERENCE"; then
    return 3
  fi
  backup_job=$(selected_metadata_value '.job // ""') || return 3
  backup_source=$(selected_metadata_value '.source.type // ""') || return 3
  if [[ $backup_source != docker_compose ]]; then
    log error "kind=compose-restore backup_id=$BACKUP_ID message=backup-is-not-compose"
    return 2
  fi
  if ! job_index=$(find_job_index "$backup_job"); then
    log error "kind=compose-restore backup_id=$BACKUP_ID job=$backup_job message=recovery-job-not-in-config"
    return 2
  fi
  if [[ $(cfg ".jobs[$job_index].source.type") != docker_compose ]]; then
    log error "kind=compose-restore backup_id=$BACKUP_ID job=$backup_job message=recovery-job-is-not-compose"
    return 2
  fi
  printf '%s\n' "$job_index"
}

compose_restore_database_artifact() {
  local job_index=$1
  local database_index=$2
  local extension=$3
  local database=$4
  local database_name directory artifact

  database_name=$(cfg ".jobs[$job_index].source.databases[$database_index].name")
  directory="$RESTORE_DIRECTORY/databases/$database_name"
  artifact="$directory/$database.$extension"
  if [[ ! -d $directory || -L $directory || ! -r $directory || ! -f $artifact || -L $artifact || ! -r $artifact ]]; then
    log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") database=$database_name message=database-artifact-missing"
    return 3
  fi
  printf '%s\n' "$artifact"
}

compose_restore_validate_staged_artifacts() {
  local job_index=$1
  local databases_count database_index database_name database_count database_position database
  local engine format extension directory artifact

  [[ -d "$RESTORE_DIRECTORY/compose" && ! -L "$RESTORE_DIRECTORY/compose" ]] || {
    log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") message=compose-directory-missing"
    return 3
  }

  databases_count=$(cfg ".jobs[$job_index].source.databases // [] | length")
  for ((database_index = 0; database_index < databases_count; database_index++)); do
    database_name=$(cfg ".jobs[$job_index].source.databases[$database_index].name")
    engine=$(cfg ".jobs[$job_index].source.databases[$database_index].engine")
    format=$(cfg ".jobs[$job_index].source.databases[$database_index].format // \"custom\"")
    directory="$RESTORE_DIRECTORY/databases/$database_name"
    [[ -d $directory && ! -L $directory && -r $directory ]] || {
      log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") database=$database_name message=database-directory-missing"
      return 3
    }
    case "$engine" in
      postgres)
        [[ $format == custom ]] && extension=dump || extension=sql
        ;;
      mysql|mariadb) extension=sql ;;
      mssql) extension=bak ;;
      oracle) extension=dmp ;;
      *)
        log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") database=$database_name message=unsupported-engine"
        return 2
        ;;
    esac
    database_count=$(cfg ".jobs[$job_index].source.databases[$database_index].databases | length")
    for ((database_position = 0; database_position < database_count; database_position++)); do
      database=$(cfg ".jobs[$job_index].source.databases[$database_index].databases[$database_position]")
      artifact="$directory/$database.$extension"
      if [[ ! -f $artifact || -L $artifact || ! -r $artifact ]]; then
        log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") database=$database_name message=database-artifact-missing"
        return 3
      fi
    done
  done
}

compose_restore_print_plan() {
  local job_index=$1
  local staged=$2
  local files_count file_index file volumes_count volume_index volume
  local binds_count bind_index bind_name bind_path databases_count database_index database_name engine format
  local directory action globals
  local staged_root=$RESTORE_DIRECTORY

  if [[ $staged == false ]]; then
    staged_root="$RESTORE_DIRECTORY (planned)"
  fi
  printf 'compose_restore backup_id=%s job=%s staging=%s\n' "$BACKUP_ID" "$(cfg ".jobs[$job_index].name")" "$staged_root"
  files_count=$(cfg ".jobs[$job_index].source.files | length")
  for ((file_index = 0; file_index < files_count; file_index++)); do
    file=$(cfg ".jobs[$job_index].source.files[$file_index]")
    printf 'compose_file source=%s\n' "$RESTORE_DIRECTORY/compose/$file"
  done
  volumes_count=$(cfg ".jobs[$job_index].source.volumes // [] | length")
  for ((volume_index = 0; volume_index < volumes_count; volume_index++)); do
    volume=$(cfg ".jobs[$job_index].source.volumes[$volume_index]")
    printf 'compose_volume name=%s archive=%s\n' "$volume" "$RESTORE_DIRECTORY/volumes/$volume/data.tar"
  done
  binds_count=$(cfg ".jobs[$job_index].source.bind_mounts // [] | length")
  for ((bind_index = 0; bind_index < binds_count; bind_index++)); do
    bind_name=$(cfg ".jobs[$job_index].source.bind_mounts[$bind_index].name")
    bind_path=$(cfg ".jobs[$job_index].source.bind_mounts[$bind_index].path")
    printf 'compose_bind_mount name=%s source=%s target_relative=%s\n' "$bind_name" "$RESTORE_DIRECTORY/bind-mounts/$bind_name" "$bind_path"
  done
  databases_count=$(cfg ".jobs[$job_index].source.databases // [] | length")
  for ((database_index = 0; database_index < databases_count; database_index++)); do
    database_name=$(cfg ".jobs[$job_index].source.databases[$database_index].name")
    engine=$(cfg ".jobs[$job_index].source.databases[$database_index].engine")
    format=$(cfg ".jobs[$job_index].source.databases[$database_index].format // \"custom\"")
    directory="$RESTORE_DIRECTORY/databases/$database_name"
    case "$engine" in
      postgres|mysql|mariadb) action=apply-available ;;
      mssql|oracle) action=vendor-manual-required ;;
      *) action=unsupported ;;
    esac
    printf 'compose_database name=%s engine=%s format=%s directory=%s action=%s\n' "$database_name" "$engine" "$format" "$directory" "$action"
    globals=$(cfg ".jobs[$job_index].source.databases[$database_index].include_globals // false")
    if [[ $engine == postgres && $globals == true ]]; then
      printf 'compose_database_globals name=%s source=%s action=manual-review-required\n' "$database_name" "$directory/globals.sql"
    fi
  done
  if [[ $COMPOSE_RESTORE_APPLY == false ]]; then
    printf '%s\n' 'next=review-staged-data-and-prepare-an-isolated-target-project; use --project-dir DIRECTORY --apply --confirm only for logical PostgreSQL/MySQL/MariaDB imports'
  fi
}

preflight_compose_restore_target() {
  local job_index=$1
  local project_dir=$2
  local job_name canonical_project files_count file_index file source_file canonical_file
  local services databases_count database_index service container_id

  require_command docker
  require_command grep
  require_command realpath
  validate_absolute_path restore-compose.project_dir "$project_dir"
  job_name=$(cfg ".jobs[$job_index].name")
  if [[ ! -d $project_dir || -L $project_dir || ! -r $project_dir || ! -x $project_dir ]]; then
    log error "kind=compose-restore job=$job_name message=target-project-not-readable"
    return 2
  fi
  canonical_project=$(realpath -e -- "$project_dir") || return 2
  files_count=$(cfg ".jobs[$job_index].source.files | length")
  for ((file_index = 0; file_index < files_count; file_index++)); do
    file=$(cfg ".jobs[$job_index].source.files[$file_index]")
    source_file="$project_dir/$file"
    if [[ ! -f $source_file || -L $source_file || ! -r $source_file ]]; then
      log error "kind=compose-restore job=$job_name file=$file message=target-compose-file-not-readable"
      return 2
    fi
    canonical_file=$(realpath -e -- "$source_file") || return 2
    if ! path_is_within "$canonical_file" "$canonical_project"; then
      log error "kind=compose-restore job=$job_name file=$file message=target-compose-file-outside-project"
      return 2
    fi
  done
  if ! docker_compose_target_project "$job_index" "$project_dir" version >/dev/null \
    || ! docker_compose_target_project "$job_index" "$project_dir" config --quiet >/dev/null; then
    log error "kind=compose-restore job=$job_name message=target-compose-project-invalid-or-unavailable"
    return 3
  fi
  services=$(docker_compose_target_project "$job_index" "$project_dir" config --services) || {
    log error "kind=compose-restore job=$job_name message=target-compose-services-unavailable"
    return 3
  }
  databases_count=$(cfg ".jobs[$job_index].source.databases // [] | length")
  for ((database_index = 0; database_index < databases_count; database_index++)); do
    service=$(cfg ".jobs[$job_index].source.databases[$database_index].service")
    if ! grep -Fx -- "$service" <<<"$services" >/dev/null; then
      log error "kind=compose-restore job=$job_name service=$service message=target-database-service-not-found"
      return 2
    fi
    container_id=$(docker_compose_target_project "$job_index" "$project_dir" ps -q "$service") || {
      log error "kind=compose-restore job=$job_name service=$service message=target-database-container-unavailable"
      return 3
    }
    if [[ ! $container_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      log error "kind=compose-restore job=$job_name service=$service message=target-database-container-not-running"
      return 3
    fi
  done
}

compose_restore_apply_database() {
  local job_index=$1
  local database_index=$2
  local project_dir=$3
  local database_name engine format service user database_count database_position database artifact

  database_name=$(cfg ".jobs[$job_index].source.databases[$database_index].name")
  engine=$(cfg ".jobs[$job_index].source.databases[$database_index].engine")
  format=$(cfg ".jobs[$job_index].source.databases[$database_index].format // \"custom\"")
  service=$(cfg ".jobs[$job_index].source.databases[$database_index].service")
  user=$(cfg ".jobs[$job_index].source.databases[$database_index].user")
  database_count=$(cfg ".jobs[$job_index].source.databases[$database_index].databases | length")

  for ((database_position = 0; database_position < database_count; database_position++)); do
    database=$(cfg ".jobs[$job_index].source.databases[$database_index].databases[$database_position]")
    case "$engine" in
      postgres)
        if [[ $format == custom ]]; then
          artifact=$(compose_restore_database_artifact "$job_index" "$database_index" dump "$database") || return $?
          if ! compose_target_exec_with_secret "$job_index" "$database_index" "$project_dir" PGPASSWORD "$service" \
            pg_restore --clean --if-exists --no-owner --no-privileges --username "$user" --dbname "$database" <"$artifact"; then
            log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") database=$database_name message=database-import-failed"
            return 3
          fi
        else
          artifact=$(compose_restore_database_artifact "$job_index" "$database_index" sql "$database") || return $?
          if ! compose_target_exec_with_secret "$job_index" "$database_index" "$project_dir" PGPASSWORD "$service" \
            psql --set=ON_ERROR_STOP=1 --username "$user" --dbname "$database" <"$artifact"; then
            log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") database=$database_name message=database-import-failed"
            return 3
          fi
        fi
        ;;
      mysql)
        artifact=$(compose_restore_database_artifact "$job_index" "$database_index" sql "$database") || return $?
        if ! compose_target_exec_with_secret "$job_index" "$database_index" "$project_dir" MYSQL_PWD "$service" \
          mysql --user="$user" <"$artifact"; then
          log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") database=$database_name message=database-import-failed"
          return 3
        fi
        ;;
      mariadb)
        artifact=$(compose_restore_database_artifact "$job_index" "$database_index" sql "$database") || return $?
        if ! compose_target_exec_with_secret "$job_index" "$database_index" "$project_dir" MYSQL_PWD "$service" \
          mariadb --user="$user" <"$artifact"; then
          log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") database=$database_name message=database-import-failed"
          return 3
        fi
        ;;
      *) return 2 ;;
    esac
    log info "event=compose-restore-database-applied job=$(cfg ".jobs[$job_index].name") database=$database_name engine=$engine service=$service target_project=$project_dir"
  done
}

compose_restore_apply() {
  local job_index=$1
  local databases_count database_index database_name engine

  databases_count=$(cfg ".jobs[$job_index].source.databases // [] | length")
  if ((databases_count == 0)); then
    log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") message=no-logical-database-dumps-configured"
    return 2
  fi
  for ((database_index = 0; database_index < databases_count; database_index++)); do
    database_name=$(cfg ".jobs[$job_index].source.databases[$database_index].name")
    engine=$(cfg ".jobs[$job_index].source.databases[$database_index].engine")
    case "$engine" in
      postgres|mysql|mariadb) : ;;
      mssql|oracle)
        log error "kind=compose-restore job=$(cfg ".jobs[$job_index].name") database=$database_name engine=$engine message=vendor-manual-recovery-required"
        return 2
        ;;
      *) return 2 ;;
    esac
  done
  preflight_compose_restore_target "$job_index" "$COMPOSE_RESTORE_PROJECT_DIRECTORY" || return $?
  for ((database_index = 0; database_index < databases_count; database_index++)); do
    compose_restore_apply_database "$job_index" "$database_index" "$COMPOSE_RESTORE_PROJECT_DIRECTORY" || return $?
  done
}

restore_compose_command() {
  local job_index result

  if job_index=$(compose_restore_prepare); then
    :
  else
    result=$?
    return "$result"
  fi
  if restore_command; then
    :
  else
    result=$?
    return "$result"
  fi
  if [[ $DRY_RUN == true ]]; then
    compose_restore_print_plan "$job_index" false
    log info "event=plan-compose-restore backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME to=$RESTORE_DIRECTORY"
    return 0
  fi
  compose_restore_validate_staged_artifacts "$job_index" || return $?
  compose_restore_print_plan "$job_index" true
  if [[ $COMPOSE_RESTORE_APPLY == false ]]; then
    log info "event=compose-restore-staged backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME to=$RESTORE_DIRECTORY"
    return 0
  fi
  compose_restore_apply "$job_index" || return $?
  log info "event=compose-restore-applied backup_id=$BACKUP_ID destination=$BACKUP_DESTINATION_NAME to=$RESTORE_DIRECTORY target_project=$COMPOSE_RESTORE_PROJECT_DIRECTORY"
}

pin_command() {
  local destination_index destination_name existing_reason reason_present=false
  local found=0 result=0

  validate_identifier backup_id "$BACKUP_REFERENCE"
  [[ -z $PIN_REASON ]] || reason_present=true
  require_command flock
  if ! acquire_lock; then
    return 3
  fi
  if ! make_work_directory; then
    return 3
  fi

  for ((destination_index = 0; destination_index < DESTINATION_COUNT; destination_index++)); do
    destination_name=$(cfg ".destinations[$destination_index].name")
    [[ -z $SELECTED_DESTINATION || $destination_name == "$SELECTED_DESTINATION" ]] || continue
    if ! validate_backup_bundle "$destination_index" "$BACKUP_REFERENCE"; then
      if [[ -n $SELECTED_DESTINATION ]]; then
        log error "kind=pin backup_id=$BACKUP_REFERENCE destination=$destination_name message=backup-not-complete"
        cleanup_work_directory
        return 2
      fi
      continue
    fi
    found=$((found + 1))

    if existing_reason=$(pinned_marker_reason "$destination_index" "$BACKUP_REFERENCE") \
      && [[ $existing_reason == "$PIN_REASON" ]]; then
      log info "event=pin-already-pinned backup_id=$BACKUP_REFERENCE destination=$destination_name reason_present=$reason_present reason_length=${#PIN_REASON}"
      continue
    fi

    if write_pinned_marker "$destination_index" "$BACKUP_REFERENCE" "$PIN_REASON"; then
      log info "event=backup-pinned backup_id=$BACKUP_REFERENCE destination=$destination_name reason_present=$reason_present reason_length=${#PIN_REASON}"
    else
      log error "kind=pin backup_id=$BACKUP_REFERENCE destination=$destination_name message=marker-write-failed"
      result=3
    fi
  done

  cleanup_work_directory
  if ((found == 0)); then
    log error "kind=pin backup_id=$BACKUP_REFERENCE message=backup-not-found-or-incomplete"
    return 2
  fi
  return "$result"
}

unpin_command() {
  local destination_index destination_name
  local found=0 removed=0 result=0

  validate_identifier backup_id "$BACKUP_REFERENCE"
  require_command flock
  if ! acquire_lock; then
    return 3
  fi

  for ((destination_index = 0; destination_index < DESTINATION_COUNT; destination_index++)); do
    destination_name=$(cfg ".destinations[$destination_index].name")
    [[ -z $SELECTED_DESTINATION || $destination_name == "$SELECTED_DESTINATION" ]] || continue
    backup_is_pinned "$destination_index" "$BACKUP_REFERENCE" || continue
    found=$((found + 1))
    if remove_pinned_marker "$destination_index" "$BACKUP_REFERENCE"; then
      removed=$((removed + 1))
    else
      log error "kind=unpin backup_id=$BACKUP_REFERENCE destination=$destination_name message=marker-remove-failed"
      result=3
    fi
  done

  if ((found == 0)); then
    log error "kind=unpin backup_id=$BACKUP_REFERENCE message=not-pinned"
    return 2
  fi
  if ((result == 0)); then
    log info "event=unpin unpinned=$BACKUP_REFERENCE destinations=$removed"
  fi
  return "$result"
}

declare -a PRUNE_RECORDS=()
declare -a PRUNE_PINNED_RECORDS=()

cleanup_orphaned_pinned_markers() {
  local destination_index=$1
  local backup_id

  while IFS= read -r -d '' backup_id; do
    backup_id_belongs_to_current_host "$backup_id" || continue
    [[ $backup_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    if ! destination_object_exists "$destination_index" "$backup_id.complete"; then
      remove_pinned_marker "$destination_index" "$backup_id" || return 1
    fi
  done < <(iterate_destination_pinned_ids "$destination_index")
}

doctor_pinned_marker_warnings() {
  local destination_index=$1
  local destination_name backup_id

  destination_name=$(cfg ".destinations[$destination_index].name")
  while IFS= read -r -d '' backup_id; do
    backup_id_belongs_to_current_host "$backup_id" || continue
    if [[ ! $backup_id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
      log warning "kind=pin destination=$destination_name message=invalid-orphaned-marker"
    elif ! destination_object_exists "$destination_index" "$backup_id.complete"; then
      log warning "kind=pin destination=$destination_name backup_id=$backup_id message=orphaned-marker"
    fi
  done < <(iterate_destination_pinned_ids "$destination_index")
}

collect_prune_records() {
  local destination_index=$1
  local job=$2
  local backup_id metadata_job created payload
  local -a unsorted=() pinned_unsorted=()
  PRUNE_RECORDS=()
  PRUNE_PINNED_RECORDS=()

  while IFS= read -r -d '' backup_id; do
    backup_id_belongs_to_current_host_job "$backup_id" "$job" || continue
    validate_identifier backup_id "$backup_id"
    if ! validate_backup_bundle "$destination_index" "$backup_id"; then
      log error "kind=prune backup_id=$backup_id message=invalid-complete-bundle"
      return 3
    fi
    metadata_job=$(destination_metadata_value "$destination_index" "$backup_id" '.job // ""')
    [[ $metadata_job == "$job" ]] || continue
    created=$(destination_metadata_value "$destination_index" "$backup_id" '.created_at // ""')
    payload=$(destination_metadata_value "$destination_index" "$backup_id" '.payload_file // ""')
    [[ $created =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 3
    if backup_is_pinned "$destination_index" "$backup_id"; then
      pinned_unsorted+=("$created|$backup_id|$payload")
    else
      unsorted+=("$created|$backup_id|$payload")
    fi
  done < <(iterate_destination_backup_ids "$destination_index")

  if ((${#unsorted[@]} > 0)); then
    mapfile -t PRUNE_RECORDS < <(printf '%s\n' "${unsorted[@]+"${unsorted[@]}"}" | sort -r)
  fi
  if ((${#pinned_unsorted[@]} > 0)); then
    mapfile -t PRUNE_PINNED_RECORDS < <(printf '%s\n' "${pinned_unsorted[@]+"${pinned_unsorted[@]}"}" | sort -r)
  fi
}

delete_backup_bundle() {
  local destination_index=$1
  local backup_id=$2
  local payload=$3
  local type signature=""
  local -a local_objects
  type=$(destination_type "$destination_index")
  if backup_uses_minisign "$destination_index" "$backup_id"; then
    signature=$(signature_filename "$backup_id")
  fi
  case "$type" in
    local)
      # Remove the commit marker first. An interrupted deletion can leave
      # harmless orphan files, but never a partial bundle that looks complete.
      local_objects=(
        "$(destination_object "$destination_index" "$backup_id.complete")"
        "$(destination_object "$destination_index" "$payload")"
        "$(destination_object "$destination_index" "$backup_id.metadata.json")"
        "$(destination_object "$destination_index" "$backup_id.sha256")"
      )
      [[ -z $signature ]] || local_objects+=("$(destination_object "$destination_index" "$signature")")
      rm -f -- "${local_objects[@]+"${local_objects[@]}"}"
      ;;
    rclone)
      require_command rclone
      # Remove the commit marker first. A deletion failure after this point may
      # leave harmless orphan objects, but never a false completed bundle.
      rclone deletefile "$(destination_object "$destination_index" "$backup_id.complete")" \
        && rclone deletefile "$(destination_object "$destination_index" "$payload")" \
        && rclone deletefile "$(destination_object "$destination_index" "$backup_id.metadata.json")" \
        && rclone deletefile "$(destination_object "$destination_index" "$backup_id.sha256")" \
        && { [[ -z $signature ]] || rclone deletefile "$(destination_object "$destination_index" "$signature")"; }
      ;;
    *) return 1 ;;
  esac
}

prune_payload_size_bytes() {
  local destination_index=$1
  local payload=$2
  local type object bytes

  type=$(destination_type "$destination_index")
  object=$(destination_object "$destination_index" "$payload")
  case "$type" in
    local)
      stat --format='%s' "$object" 2>/dev/null || printf '0\n'
      ;;
    rclone)
      if bytes=$(rclone lsf --files-only --format s "$object" 2>/dev/null) \
        && [[ $bytes =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$bytes"
      else
        printf '0\n'
      fi
      ;;
    *) printf '0\n' ;;
  esac
}

prune_job_destination() {
  local job_index=$1
  local destination_index=$2
  local job destination destination_path destination_type_value keep_last keep_daily keep_weekly keep_monthly min_keep max_age_days
  local -a records=() pinned_records=()
  local -A keep=() minimum_keep=() seen_daily=() seen_weekly=() seen_monthly=()
  local record created backup_id payload payload_bytes index bucket daily_count=0 weekly_count=0 monthly_count=0
  local now_seconds max_age_seconds created_seconds prune_reason

  job=$(cfg ".jobs[$job_index].name")
  destination=$(cfg ".destinations[$destination_index].name")
  destination_type_value=$(destination_type "$destination_index")
  if [[ $destination_type_value == local ]]; then
    destination_path=$(destination_local_path "$destination_index")
    [[ -d $destination_path ]] || return 0
  fi
  keep_last=$(cfg ".jobs[$job_index].retention.keep_last // 3")
  keep_daily=$(cfg ".jobs[$job_index].retention.keep_daily // 0")
  keep_weekly=$(cfg ".jobs[$job_index].retention.keep_weekly // 0")
  keep_monthly=$(cfg ".jobs[$job_index].retention.keep_monthly // 0")
  min_keep=$(cfg ".jobs[$job_index].retention.min_keep // 1")
  max_age_days=$(cfg ".jobs[$job_index].retention.max_age_days // 0")
  now_seconds=$(date -u +%s)
  max_age_seconds=$((max_age_days * 86400))

  if [[ $DRY_RUN == false ]] && ! cleanup_orphaned_pinned_markers "$destination_index"; then
    log error "kind=prune job=$job destination=$destination message=orphaned-pin-cleanup-failed"
    return 3
  fi
  if ! collect_prune_records "$destination_index" "$job"; then
    log error "kind=prune job=$job destination=$destination message=bundle-validation-failed"
    return 3
  fi
  records=("${PRUNE_RECORDS[@]+"${PRUNE_RECORDS[@]}"}")
  pinned_records=("${PRUNE_PINNED_RECORDS[@]+"${PRUNE_PINNED_RECORDS[@]}"}")

  if ((${#pinned_records[@]} > keep_last)); then
    log warning "event=prune-warning job=$job destination=$destination pinned=${#pinned_records[@]} may exceed keep_last=$keep_last"
  fi
  if [[ $DRY_RUN == true ]]; then
    for record in "${pinned_records[@]+"${pinned_records[@]}"}"; do
      IFS='|' read -r created backup_id payload <<<"$record"
      log info "event=plan-retain job=$job destination=$destination backup_id=$backup_id reason=pinned"
    done
  fi
  ((${#records[@]} > 0)) || return 0

  for ((index = 0; index < ${#records[@]} && index < keep_last; index++)); do
    IFS='|' read -r created backup_id payload <<<"${records[$index]}"
    keep["$backup_id"]=1
  done

  # This floor is independent of GFS slots and max_age_days. It prevents a
  # prolonged failed backup run from expiring every ordinary recovery copy.
  for ((index = 0; index < ${#records[@]} && index < min_keep; index++)); do
    IFS='|' read -r created backup_id payload <<<"${records[$index]}"
    minimum_keep["$backup_id"]=1
  done

  for record in "${records[@]+"${records[@]}"}"; do
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

  for record in "${records[@]+"${records[@]}"}"; do
    IFS='|' read -r created backup_id payload <<<"$record"
    prune_reason=''
    if [[ -n ${minimum_keep[$backup_id]+x} ]]; then
      if [[ $DRY_RUN == true ]]; then
        log info "event=plan-retain job=$job destination=$destination backup_id=$backup_id reason=min-keep"
      fi
      continue
    fi
    if ((max_age_days > 0)); then
      if ! created_seconds=$(date -u -d "$created" +%s); then
        log error "kind=prune job=$job destination=$destination backup_id=$backup_id message=created-at-parse-failed"
        return 3
      fi
      if ((now_seconds - created_seconds > max_age_seconds)); then
        # max_age_days overrides GFS slots, but never the independent
        # min_keep recovery floor. Pins remain the explicit longer-lived
        # operator escape hatch.
        prune_reason=max-age
      fi
    fi
    [[ -n $prune_reason || -z ${keep[$backup_id]+x} ]] || continue
    if backup_is_pinned "$destination_index" "$backup_id"; then
      log info "event=backup-retained job=$job destination=$destination backup_id=$backup_id reason=pinned"
      continue
    fi
    if [[ $DRY_RUN == true ]]; then
      log info "event=plan-prune job=$job destination=$destination backup_id=$backup_id${prune_reason:+ reason=$prune_reason}"
      continue
    fi
    payload_bytes=$(prune_payload_size_bytes "$destination_index" "$payload")
    [[ $payload_bytes =~ ^[0-9]+$ ]] || payload_bytes=0
    if delete_backup_bundle "$destination_index" "$backup_id" "$payload"; then
      PRUNE_DELETED_IDS+=("$backup_id")
      PRUNE_FREED_BYTES=$((PRUNE_FREED_BYTES + payload_bytes))
      log info "event=backup-pruned job=$job destination=$destination backup_id=$backup_id${prune_reason:+ reason=$prune_reason}"
    else
      log error "kind=prune job=$job destination=$destination backup_id=$backup_id message=delete-failed"
      return 3
    fi
  done
}

delete_period_job_destination() {
  local job_index=$1
  local destination_index=$2
  local start_seconds=$3
  local end_seconds=$4
  local job destination destination_type_value destination_path
  local record _ backup_id payload backup_seconds payload_bytes
  local -a records=() pinned_records=()

  job=$(cfg ".jobs[$job_index].name")
  destination=$(cfg ".destinations[$destination_index].name")
  destination_type_value=$(destination_type "$destination_index")
  if [[ $destination_type_value == local ]]; then
    destination_path=$(destination_local_path "$destination_index")
    [[ -d $destination_path ]] || return 0
  fi

  if ! collect_prune_records "$destination_index" "$job"; then
    log error "kind=delete-period job=$job destination=$destination message=bundle-validation-failed"
    return 3
  fi
  records=("${PRUNE_RECORDS[@]+"${PRUNE_RECORDS[@]}"}")
  pinned_records=("${PRUNE_PINNED_RECORDS[@]+"${PRUNE_PINNED_RECORDS[@]}"}")

  for record in "${pinned_records[@]+"${pinned_records[@]}"}"; do
    IFS='|' read -r _ backup_id payload <<<"$record"
    if ! backup_seconds=$(backup_id_timestamp_seconds "$backup_id" "$job"); then
      log error "kind=delete-period job=$job destination=$destination backup_id=$backup_id message=invalid-backup-timestamp"
      return 3
    fi
    ((backup_seconds >= start_seconds && backup_seconds < end_seconds)) || continue
    log info "event=backup-retained job=$job destination=$destination backup_id=$backup_id reason=pinned"
  done

  for record in "${records[@]+"${records[@]}"}"; do
    IFS='|' read -r _ backup_id payload <<<"$record"
    if ! backup_seconds=$(backup_id_timestamp_seconds "$backup_id" "$job"); then
      log error "kind=delete-period job=$job destination=$destination backup_id=$backup_id message=invalid-backup-timestamp"
      return 3
    fi
    ((backup_seconds >= start_seconds && backup_seconds < end_seconds)) || continue
    if backup_is_pinned "$destination_index" "$backup_id"; then
      log info "event=backup-retained job=$job destination=$destination backup_id=$backup_id reason=pinned"
      continue
    fi
    if [[ $DRY_RUN == true ]]; then
      log info "event=plan-delete-period job=$job destination=$destination backup_id=$backup_id since=$DELETE_PERIOD_SINCE until=$DELETE_PERIOD_UNTIL"
      continue
    fi
    payload_bytes=$(prune_payload_size_bytes "$destination_index" "$payload")
    [[ $payload_bytes =~ ^[0-9]+$ ]] || payload_bytes=0
    if delete_backup_bundle "$destination_index" "$backup_id" "$payload"; then
      log info "event=backup-deleted job=$job destination=$destination backup_id=$backup_id bytes=$payload_bytes since=$DELETE_PERIOD_SINCE until=$DELETE_PERIOD_UNTIL"
    else
      log error "kind=delete-period job=$job destination=$destination backup_id=$backup_id message=delete-failed"
      return 3
    fi
  done
}

delete_period_command() {
  local since_seconds until_start_seconds end_seconds
  local job_index destination_position destination_count destination_name destination_index result=0

  [[ -n $SELECTED_JOB ]] || command_error "delete-period-requires-job"
  [[ -n $DELETE_PERIOD_SINCE && -n $DELETE_PERIOD_UNTIL ]] \
    || command_error "delete-period-requires-since-and-until"
  [[ $DRY_RUN == true || $DELETE_PERIOD_CONFIRMED == true ]] \
    || command_error "delete-period-requires-confirm-or-dry-run"

  require_command find
  require_command sort
  require_command date
  if ! since_seconds=$(utc_date_start_seconds "$DELETE_PERIOD_SINCE"); then
    command_error "delete-period-invalid-since expected=YYYY-MM-DD"
  fi
  if ! until_start_seconds=$(utc_date_start_seconds "$DELETE_PERIOD_UNTIL"); then
    command_error "delete-period-invalid-until expected=YYYY-MM-DD"
  fi
  ((since_seconds <= until_start_seconds)) \
    || command_error "delete-period-since-must-not-be-after-until"
  end_seconds=$((until_start_seconds + 86400))

  if [[ $DRY_RUN == false ]]; then
    require_command flock
    if ! acquire_lock; then
      return 3
    fi
  fi

  job_index=$(find_job_index "$SELECTED_JOB") || return 2
  destination_count=$(cfg ".jobs[$job_index].destinations | length")
  for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
    destination_name=$(cfg ".jobs[$job_index].destinations[$destination_position]")
    [[ -z $SELECTED_DESTINATION || $destination_name == "$SELECTED_DESTINATION" ]] || continue
    destination_index=$(find_destination_index "$destination_name")
    if ! delete_period_job_destination "$job_index" "$destination_index" "$since_seconds" "$end_seconds"; then
      result=3
    fi
  done
  log info "event=delete-period-complete job=$SELECTED_JOB since=$DELETE_PERIOD_SINCE until=$DELETE_PERIOD_UNTIL dry_run=$DRY_RUN"
  return "$result"
}

prune_command() {
  PRUNE_DELETED_IDS=()
  PRUNE_FREED_BYTES=0
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
  # Doctor is intentionally stricter than run: it reports every configured
  # destination that cannot be reached or prepared before a scheduled run.
  preflight_prometheus_metrics
  preflight_selected_jobs true
  local index name destination_count destination_position destination_name destination_index
  local -A checked_destinations=()
  for ((index = 0; index < JOB_COUNT; index++)); do
    name=$(cfg ".jobs[$index].name")
    [[ -z $SELECTED_JOB || $name == "$SELECTED_JOB" ]] || continue
    destination_count=$(cfg ".jobs[$index].destinations | length")
    for ((destination_position = 0; destination_position < destination_count; destination_position++)); do
      destination_name=$(cfg ".jobs[$index].destinations[$destination_position]")
      [[ -z ${checked_destinations[$destination_name]+x} ]] || continue
      checked_destinations["$destination_name"]=1
      destination_index=$(find_destination_index "$destination_name")
      doctor_pinned_marker_warnings "$destination_index"
    done
    log info "event=doctor-job-ok job=$name"
  done
  doctor_notification_channels
  log info "event=doctor-succeeded version=$BACKFORT_VERSION"
}

quick_compose_require_single_line() {
  local field=$1
  local value=$2

  [[ -n $value && $value != *$'\n'* && $value != *$'\r'* ]] \
    || command_error "quick-compose-invalid-$field"
}

quick_compose_default_name() {
  local project_dir=${QUICK_COMPOSE_PROJECT_DIR%/}
  local name=${project_dir##*/}

  name=${name//[^A-Za-z0-9._-]/-}
  while [[ $name == [._-]* ]]; do
    name=${name:1}
  done
  [[ -n $name ]] || name=compose
  printf 'quick-%s\n' "$name"
}

quick_host_component() {
  local value=${BACKFORT_QUICK_HOST_ID:-}

  if [[ -n $value ]]; then
    validate_identifier quick.host_override "$value"
    printf '%s\n' "$value"
    return 0
  fi

  value=$(hostname -s 2>/dev/null || true)
  [[ -n $value ]] || value=${HOSTNAME:-}
  if [[ -z $value && -r /etc/hostname ]]; then
    IFS= read -r value </etc/hostname || true
  fi
  value=${value//[^A-Za-z0-9._-]/-}
  while [[ $value == [._-]* ]]; do
    value=${value:1}
  done
  [[ -n $value ]] || command_error "quick-host-id-unavailable set=BACKFORT_QUICK_HOST_ID"
  printf '%s\n' "$value"
}

quick_destination_name() {
  local position=$1
  local destination=$2
  local type=local

  [[ $destination == rclone:* ]] && type=rclone
  printf 'quick-%s-%s\n' "$type" "$position"
}

quick_default_state_directory() {
  if [[ -n ${XDG_STATE_HOME:-} ]]; then
    printf '%s/backfort\n' "$XDG_STATE_HOME"
  elif [[ -n ${HOME:-} ]]; then
    printf '%s/.local/state/backfort\n' "$HOME"
  else
    printf '/var/lib/backfort\n'
  fi
}

quick_require_single_line() {
  local field=$1
  local value=$2

  [[ -n $value && $value != *$'\n'* && $value != *$'\r'* ]] \
    || command_error "quick-invalid-$field"
}

quick_default_name() {
  local path=${QUICK_PATHS[0]%/}
  local name=${path##*/}

  name=${name//[^A-Za-z0-9._-]/-}
  while [[ $name == [._-]* ]]; do
    name=${name:1}
  done
  [[ -n $name ]] || name=files
  printf 'quick-%s\n' "$name"
}

quick_save_config() {
  local config_directory temporary_config

  config_directory="$QUICK_STATE_DIRECTORY/quick"
  QUICK_CONFIG_SAVED_PATH="$config_directory/$QUICK_NAME.yaml"
  temporary_config="$config_directory/.${QUICK_NAME}.yaml.tmp.$$"
  if ! mkdir -p -- "$config_directory" \
    || ! chmod 0700 "$QUICK_STATE_DIRECTORY" "$config_directory" \
    || ! cp -- "$CONFIG_FILE" "$temporary_config" \
    || ! chmod 0600 "$temporary_config" \
    || ! mv -f -- "$temporary_config" "$QUICK_CONFIG_SAVED_PATH"; then
    rm -f -- "$temporary_config" 2>/dev/null || true
    config_error "quick-recovery-config-save-failed path=$QUICK_CONFIG_SAVED_PATH"
  fi
  log info "event=quick-config-saved file=$QUICK_CONFIG_SAVED_PATH"
}

quick_write_config() {
  local job_name host_id destination_position destination destination_name remote remote_path
  local path exclude
  local -a destination_names=()

  ((${#QUICK_PATHS[@]} > 0)) || command_error "quick-requires-path"
  ((${#QUICK_DESTINATIONS[@]} > 0)) || command_error "quick-requires-destination"
  validate_integer quick.min_copies "$QUICK_MIN_COPIES"
  ((10#$QUICK_MIN_COPIES > 0)) || command_error "quick-min-copies-must-be-positive"
  QUICK_MIN_COPIES=$((10#$QUICK_MIN_COPIES))

  if [[ -z $QUICK_NAME ]]; then
    QUICK_NAME=$(quick_default_name)
  fi
  validate_identifier quick.name "$QUICK_NAME"
  if [[ -z $QUICK_STATE_DIRECTORY ]]; then
    QUICK_STATE_DIRECTORY=$(quick_default_state_directory)
  fi
  validate_absolute_path quick.state_directory "$QUICK_STATE_DIRECTORY"
  job_name=$QUICK_NAME
  host_id="quick-$(quick_host_component)-$job_name"
  validate_identifier quick.host_id "$host_id"

  for path in "${QUICK_PATHS[@]+"${QUICK_PATHS[@]}"}"; do
    quick_require_single_line path "$path"
    validate_absolute_path quick.path "$path"
  done
  for destination in "${QUICK_DESTINATIONS[@]+"${QUICK_DESTINATIONS[@]}"}"; do
    quick_require_single_line destination "$destination"
  done
  for exclude in "${QUICK_EXCLUDES[@]+"${QUICK_EXCLUDES[@]}"}"; do
    quick_require_single_line exclude "$exclude"
  done

  QUICK_CONFIG_DIRECTORY=$(mktemp -d /tmp/backfort.quick.XXXXXXXX) \
    || command_error "quick-temporary-config-create-failed"
  chmod 0700 "$QUICK_CONFIG_DIRECTORY"
  CONFIG_FILE="$QUICK_CONFIG_DIRECTORY/config.yaml"

  {
    printf 'version: 1\n'
    printf 'settings:\n'
    printf '  host_id: %s\n' "$(yaml_quote "$host_id")"
    printf '  state_directory: %s\n' "$(yaml_quote "$QUICK_STATE_DIRECTORY")"
    printf '  temp_directory: %s\n' "$(yaml_quote "$QUICK_STATE_DIRECTORY/tmp")"
    printf '  lock_file: %s\n' "$(yaml_quote "$QUICK_STATE_DIRECTORY/backfort.lock")"
    printf '  min_free_mb: 0\n'
    printf 'destinations:\n'
    for ((destination_position = 0; destination_position < ${#QUICK_DESTINATIONS[@]}; destination_position++)); do
      destination=${QUICK_DESTINATIONS[destination_position]}
      destination_name=$(quick_destination_name "$((destination_position + 1))" "$destination")
      destination_names+=("$destination_name")
      printf '  - name: %s\n' "$(yaml_quote "$destination_name")"
      if [[ $destination == rclone:* ]]; then
        remote=${destination#rclone:}
        [[ $remote == *:* ]] || command_error "quick-rclone-destination-must-be-rclone-remote-path"
        remote_path=${remote#*:}
        remote=${remote%%:*}
        [[ -n $remote && -n $remote_path ]] \
          || command_error "quick-rclone-destination-must-be-rclone-remote-path"
        printf '    type: rclone\n'
        printf '    remote: %s\n' "$(yaml_quote "$remote")"
        printf '    path: %s\n' "$(yaml_quote "$remote_path")"
      else
        printf '    type: local\n'
        printf '    path: %s\n' "$(yaml_quote "$destination")"
      fi
    done

    printf 'jobs:\n'
    printf '  - name: %s\n' "$(yaml_quote "$job_name")"
    printf '    source:\n'
    printf '      type: files\n'
    printf '      paths:\n'
    for path in "${QUICK_PATHS[@]+"${QUICK_PATHS[@]}"}"; do
      printf '        - %s\n' "$(yaml_quote "$path")"
    done
    if ((${#QUICK_EXCLUDES[@]} == 0)); then
      printf '      exclude: []\n'
    else
      printf '      exclude:\n'
      for exclude in "${QUICK_EXCLUDES[@]+"${QUICK_EXCLUDES[@]}"}"; do
        printf '        - %s\n' "$(yaml_quote "$exclude")"
      done
    fi
    printf '      follow_symlinks: %s\n' "$QUICK_FOLLOW_SYMLINKS"
    printf '    destinations:\n'
    for destination_name in "${destination_names[@]+"${destination_names[@]}"}"; do
      printf '      - %s\n' "$(yaml_quote "$destination_name")"
    done
    printf '    success:\n'
    printf '      min_copies: %s\n' "$QUICK_MIN_COPIES"
    printf '    compression: {method: gzip, level: 6}\n'
    printf '    encryption: {method: none}\n'
    printf '    retention: {keep_last: 3, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}\n'
  } >"$CONFIG_FILE"
}

quick_command() {
  quick_write_config
  validate_config
  [[ $DRY_RUN == true ]] || quick_save_config
  run_command
}

quick_compose_save_config() {
  local config_directory temporary_config

  config_directory="$QUICK_COMPOSE_STATE_DIRECTORY/quick-compose"
  QUICK_CONFIG_SAVED_PATH="$config_directory/$QUICK_COMPOSE_NAME.yaml"
  temporary_config="$config_directory/.${QUICK_COMPOSE_NAME}.yaml.tmp.$$"
  if ! mkdir -p -- "$config_directory" \
    || ! chmod 0700 "$QUICK_COMPOSE_STATE_DIRECTORY" "$config_directory" \
    || ! cp -- "$CONFIG_FILE" "$temporary_config" \
    || ! chmod 0600 "$temporary_config" \
    || ! mv -f -- "$temporary_config" "$QUICK_CONFIG_SAVED_PATH"; then
    rm -f -- "$temporary_config" 2>/dev/null || true
    config_error "quick-compose-recovery-config-save-failed path=$QUICK_CONFIG_SAVED_PATH"
  fi
  log info "event=quick-compose-config-saved file=$QUICK_CONFIG_SAVED_PATH"
}

quick_compose_write_config() {
  local job_name host_id destination_position destination destination_name remote remote_path
  local file volume bind bind_name bind_path database database_name service engine user password_env database_names
  local database_name_item
  local -a destination_names=() database_name_items=()
  local IFS=$'\n\t'

  validate_absolute_path quick-compose.project_dir "$QUICK_COMPOSE_PROJECT_DIR"
  [[ -d $QUICK_COMPOSE_PROJECT_DIR ]] || command_error "quick-compose-project-dir-not-readable"
  [[ ${#QUICK_COMPOSE_DESTINATIONS[@]} -gt 0 ]] || command_error "quick-compose-requires-destination"
  validate_integer quick-compose.min_copies "$QUICK_COMPOSE_MIN_COPIES"
  ((10#$QUICK_COMPOSE_MIN_COPIES > 0)) || command_error "quick-compose-min-copies-must-be-positive"
  QUICK_COMPOSE_MIN_COPIES=$((10#$QUICK_COMPOSE_MIN_COPIES))

  if [[ -z $QUICK_COMPOSE_NAME ]]; then
    QUICK_COMPOSE_NAME=$(quick_compose_default_name)
  fi
  validate_identifier quick-compose.name "$QUICK_COMPOSE_NAME"
  if [[ -z $QUICK_COMPOSE_STATE_DIRECTORY ]]; then
    QUICK_COMPOSE_STATE_DIRECTORY=$(quick_default_state_directory)
  fi
  validate_absolute_path quick-compose.state_directory "$QUICK_COMPOSE_STATE_DIRECTORY"
  job_name=$QUICK_COMPOSE_NAME
  host_id="quick-$(quick_host_component)-$job_name"
  validate_identifier quick-compose.host_id "$host_id"

  if ((${#QUICK_COMPOSE_FILES[@]} == 0)); then
    QUICK_COMPOSE_FILES=(compose.yaml)
  fi
  if ((${#QUICK_COMPOSE_VOLUMES[@]} > 0)); then
    [[ -n $QUICK_COMPOSE_VOLUME_HELPER_IMAGE ]] \
      || command_error "quick-compose-volume-helper-image-required"
    validate_docker_image_reference quick-compose.volume_helper_image "$QUICK_COMPOSE_VOLUME_HELPER_IMAGE"
  elif [[ -n $QUICK_COMPOSE_VOLUME_HELPER_IMAGE ]]; then
    command_error "quick-compose-volume-helper-image-without-volume"
  fi

  for file in "${QUICK_COMPOSE_FILES[@]+"${QUICK_COMPOSE_FILES[@]}"}"; do
    quick_compose_require_single_line file "$file"
  done
  for destination in "${QUICK_COMPOSE_DESTINATIONS[@]+"${QUICK_COMPOSE_DESTINATIONS[@]}"}"; do
    quick_compose_require_single_line destination "$destination"
  done
  for volume in "${QUICK_COMPOSE_VOLUMES[@]+"${QUICK_COMPOSE_VOLUMES[@]}"}"; do
    quick_compose_require_single_line volume "$volume"
  done
  for bind in "${QUICK_COMPOSE_BIND_MOUNTS[@]+"${QUICK_COMPOSE_BIND_MOUNTS[@]}"}"; do
    quick_compose_require_single_line bind "$bind"
  done
  for database in "${QUICK_COMPOSE_DATABASES[@]+"${QUICK_COMPOSE_DATABASES[@]}"}"; do
    quick_compose_require_single_line db "$database"
  done

  QUICK_CONFIG_DIRECTORY=$(mktemp -d /tmp/backfort.quick.XXXXXXXX) \
    || command_error "quick-compose-temporary-config-create-failed"
  chmod 0700 "$QUICK_CONFIG_DIRECTORY"
  CONFIG_FILE="$QUICK_CONFIG_DIRECTORY/config.yaml"

  {
    printf 'version: 1\n'
    printf 'settings:\n'
    printf '  host_id: %s\n' "$(yaml_quote "$host_id")"
    printf '  state_directory: %s\n' "$(yaml_quote "$QUICK_COMPOSE_STATE_DIRECTORY")"
    printf '  temp_directory: %s\n' "$(yaml_quote "$QUICK_COMPOSE_STATE_DIRECTORY/tmp")"
    printf '  lock_file: %s\n' "$(yaml_quote "$QUICK_COMPOSE_STATE_DIRECTORY/backfort.lock")"
    printf '  min_free_mb: 0\n'
    printf 'destinations:\n'
    for ((destination_position = 0; destination_position < ${#QUICK_COMPOSE_DESTINATIONS[@]}; destination_position++)); do
      destination=${QUICK_COMPOSE_DESTINATIONS[destination_position]}
      destination_name=$(quick_destination_name "$((destination_position + 1))" "$destination")
      destination_names+=("$destination_name")
      printf '  - name: %s\n' "$(yaml_quote "$destination_name")"
      if [[ $destination == rclone:* ]]; then
        remote=${destination#rclone:}
        [[ $remote == *:* ]] || command_error "quick-compose-rclone-destination-must-be-rclone-remote-path"
        remote_path=${remote#*:}
        remote=${remote%%:*}
        [[ -n $remote && -n $remote_path ]] \
          || command_error "quick-compose-rclone-destination-must-be-rclone-remote-path"
        printf '    type: rclone\n'
        printf '    remote: %s\n' "$(yaml_quote "$remote")"
        printf '    path: %s\n' "$(yaml_quote "$remote_path")"
      else
        printf '    type: local\n'
        printf '    path: %s\n' "$(yaml_quote "$destination")"
      fi
    done

    printf 'jobs:\n'
    printf '  - name: %s\n' "$(yaml_quote "$job_name")"
    printf '    source:\n'
    printf '      type: docker_compose\n'
    printf '      project_dir: %s\n' "$(yaml_quote "$QUICK_COMPOSE_PROJECT_DIR")"
    printf '      files:\n'
    for file in "${QUICK_COMPOSE_FILES[@]+"${QUICK_COMPOSE_FILES[@]}"}"; do
      printf '        - %s\n' "$(yaml_quote "$file")"
    done
    if ((${#QUICK_COMPOSE_VOLUMES[@]} > 0)); then
      printf '      volumes:\n'
      for volume in "${QUICK_COMPOSE_VOLUMES[@]+"${QUICK_COMPOSE_VOLUMES[@]}"}"; do
        printf '        - %s\n' "$(yaml_quote "$volume")"
      done
      printf '      volume_helper_image: %s\n' "$(yaml_quote "$QUICK_COMPOSE_VOLUME_HELPER_IMAGE")"
    fi
    if ((${#QUICK_COMPOSE_BIND_MOUNTS[@]} > 0)); then
      printf '      bind_mounts:\n'
      for bind in "${QUICK_COMPOSE_BIND_MOUNTS[@]+"${QUICK_COMPOSE_BIND_MOUNTS[@]}"}"; do
        [[ $bind == *:* ]] || command_error "quick-compose-bind-must-be-name-relative-path"
        bind_name=${bind%%:*}
        bind_path=${bind#*:}
        [[ -n $bind_name && -n $bind_path ]] \
          || command_error "quick-compose-bind-must-be-name-relative-path"
        printf '        - name: %s\n' "$(yaml_quote "$bind_name")"
        printf '          path: %s\n' "$(yaml_quote "$bind_path")"
      done
    fi
    if ((${#QUICK_COMPOSE_DATABASES[@]} > 0)); then
      printf '      databases:\n'
      for database in "${QUICK_COMPOSE_DATABASES[@]+"${QUICK_COMPOSE_DATABASES[@]}"}"; do
        IFS=:
        read -r database_name service engine user password_env database_names <<<"$database"
        [[ -n $database_name && -n $service && -n $engine && -n $user && -n $password_env && -n $database_names ]] \
          || command_error "quick-compose-db-must-be-name-service-engine-user-password-env-databases"
        case "$engine" in
          postgres|mysql|mariadb) : ;;
          *) command_error "quick-compose-db-engine-must-be-postgres-mysql-or-mariadb" ;;
        esac
        IFS=,
        read -r -a database_name_items <<<"$database_names"
        ((${#database_name_items[@]} > 0)) \
          || command_error "quick-compose-db-must-name-at-least-one-database"
        printf '        - name: %s\n' "$(yaml_quote "$database_name")"
        printf '          service: %s\n' "$(yaml_quote "$service")"
        printf '          engine: %s\n' "$(yaml_quote "$engine")"
        printf '          user: %s\n' "$(yaml_quote "$user")"
        printf '          password_env: %s\n' "$(yaml_quote "$password_env")"
        printf '          databases:\n'
        for database_name_item in "${database_name_items[@]+"${database_name_items[@]}"}"; do
          [[ -n $database_name_item ]] \
            || command_error "quick-compose-db-must-name-at-least-one-database"
          printf '            - %s\n' "$(yaml_quote "$database_name_item")"
        done
        [[ $engine != postgres ]] || printf '          format: sql\n'
      done
    fi
    printf '    destinations:\n'
    for destination_name in "${destination_names[@]+"${destination_names[@]}"}"; do
      printf '      - %s\n' "$(yaml_quote "$destination_name")"
    done
    printf '    success:\n'
    printf '      min_copies: %s\n' "$QUICK_COMPOSE_MIN_COPIES"
    printf '    compression: {method: gzip, level: 6}\n'
    printf '    encryption: {method: none}\n'
    printf '    retention: {keep_last: 3, keep_daily: 0, keep_weekly: 0, keep_monthly: 0}\n'
  } >"$CONFIG_FILE"
}

quick_compose_command() {
  quick_compose_write_config
  validate_config
  [[ $DRY_RUN == true ]] || quick_compose_save_config
  run_command
}

parse_global_options() {
  while (($# > 0)); do
    case "$1" in
      -c)
        (($# >= 2)) || command_error "missing-value option=-c"
        CONFIG_FILE=$2
        CONFIG_FILE_EXPLICIT=true
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
      run|doctor|list|status|watchdog|diff|pin|unpin|verify|restore|restore-compose|prune|delete|quick|quick-compose)
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
  set -- "${REMAINING_ARGUMENTS[@]+"${REMAINING_ARGUMENTS[@]}"}"
  case "$COMMAND" in
    quick)
      while (($# > 0)); do
        case "$1" in
          --name)
            (($# >= 2)) || command_error "missing-value option=--name"
            QUICK_NAME=$2
            shift 2
            ;;
          --to)
            (($# >= 2)) || command_error "missing-value option=--to"
            QUICK_DESTINATIONS+=("$2")
            shift 2
            ;;
          --min-copies)
            (($# >= 2)) || command_error "missing-value option=--min-copies"
            QUICK_MIN_COPIES=$2
            shift 2
            ;;
          --state-directory)
            (($# >= 2)) || command_error "missing-value option=--state-directory"
            QUICK_STATE_DIRECTORY=$2
            shift 2
            ;;
          --exclude)
            (($# >= 2)) || command_error "missing-value option=--exclude"
            QUICK_EXCLUDES+=("$2")
            shift 2
            ;;
          --follow-symlinks)
            QUICK_FOLLOW_SYMLINKS=true
            shift
            ;;
          -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
          --)
            shift
            while (($# > 0)); do
              QUICK_PATHS+=("$1")
              shift
            done
            ;;
          -*) command_error "unknown-option command=quick value=$1" ;;
          *)
            QUICK_PATHS+=("$1")
            shift
            ;;
        esac
      done
      ((${#QUICK_PATHS[@]} > 0)) || command_error "quick-requires-path"
      ((${#QUICK_DESTINATIONS[@]} > 0)) || command_error "quick-requires-destination"
      ;;
    delete)
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
          --since)
            (($# >= 2)) || command_error "missing-value option=--since"
            DELETE_PERIOD_SINCE=$2
            shift 2
            ;;
          --until)
            (($# >= 2)) || command_error "missing-value option=--until"
            DELETE_PERIOD_UNTIL=$2
            shift 2
            ;;
          --confirm)
            DELETE_PERIOD_CONFIRMED=true
            shift
            ;;
          -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
          *) command_error "unknown-option command=delete value=$1" ;;
        esac
      done
      [[ -n $SELECTED_JOB ]] || command_error "delete-period-requires-job"
      [[ -n $DELETE_PERIOD_SINCE && -n $DELETE_PERIOD_UNTIL ]] \
        || command_error "delete-period-requires-since-and-until"
      [[ $DRY_RUN == true || $DELETE_PERIOD_CONFIRMED == true ]] \
        || command_error "delete-period-requires-confirm-or-dry-run"
      ;;
    quick-compose)
      (($# > 0)) || command_error "quick-compose-requires-project-dir"
      QUICK_COMPOSE_PROJECT_DIR=$1
      shift
      while (($# > 0)); do
        case "$1" in
          --name)
            (($# >= 2)) || command_error "missing-value option=--name"
            QUICK_COMPOSE_NAME=$2
            shift 2
            ;;
          --file)
            (($# >= 2)) || command_error "missing-value option=--file"
            QUICK_COMPOSE_FILES+=("$2")
            shift 2
            ;;
          --to)
            (($# >= 2)) || command_error "missing-value option=--to"
            QUICK_COMPOSE_DESTINATIONS+=("$2")
            shift 2
            ;;
          --min-copies)
            (($# >= 2)) || command_error "missing-value option=--min-copies"
            QUICK_COMPOSE_MIN_COPIES=$2
            shift 2
            ;;
          --state-directory)
            (($# >= 2)) || command_error "missing-value option=--state-directory"
            QUICK_COMPOSE_STATE_DIRECTORY=$2
            shift 2
            ;;
          --volume)
            (($# >= 2)) || command_error "missing-value option=--volume"
            QUICK_COMPOSE_VOLUMES+=("$2")
            shift 2
            ;;
          --volume-helper-image)
            (($# >= 2)) || command_error "missing-value option=--volume-helper-image"
            QUICK_COMPOSE_VOLUME_HELPER_IMAGE=$2
            shift 2
            ;;
          --bind)
            (($# >= 2)) || command_error "missing-value option=--bind"
            QUICK_COMPOSE_BIND_MOUNTS+=("$2")
            shift 2
            ;;
          --db)
            (($# >= 2)) || command_error "missing-value option=--db"
            QUICK_COMPOSE_DATABASES+=("$2")
            shift 2
            ;;
          -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
          *) command_error "unknown-option command=quick-compose value=$1" ;;
        esac
      done
      ;;
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
    watchdog)
      while (($# > 0)); do
        case "$1" in
          --job)
            (($# >= 2)) || command_error "missing-value option=--job"
            SELECTED_JOB=$2
            shift 2
            ;;
          --max-age)
            (($# >= 2)) || command_error "missing-value option=--max-age"
            WATCHDOG_MAX_AGE_HOURS=$2
            shift 2
            ;;
          -n|--dry-run)
            command_error "dry-run-not-supported command=watchdog"
            ;;
          *) command_error "unknown-option command=watchdog value=$1" ;;
        esac
      done
      if [[ -n $WATCHDOG_MAX_AGE_HOURS ]]; then
        if [[ ! $WATCHDOG_MAX_AGE_HOURS =~ ^[0-9]+$ ]]; then
          command_error "watchdog-max-age-must-be-integer"
        fi
        if ! WATCHDOG_MAX_AGE_HOURS=$(normalize_watchdog_max_age "$WATCHDOG_MAX_AGE_HOURS"); then
          command_error "watchdog-max-age-out-of-range min=1 max=8760"
        fi
      fi
      ;;
    diff)
      (($# >= 2)) || command_error "diff-requires-two-backup-ids"
      DIFF_ID_ONE=$1
      DIFF_ID_TWO=$2
      shift 2
      while (($# > 0)); do
        case "$1" in
          --from)
            (($# >= 2)) || command_error "missing-value option=--from"
            SELECTED_DESTINATION=$2
            shift 2
            ;;
          --json)
            JSON_OUTPUT=true
            shift
            ;;
          -n|--dry-run)
            command_error "dry-run-not-supported command=diff"
            ;;
          *) command_error "unknown-option command=diff value=$1" ;;
        esac
      done
      ;;
    pin|unpin)
      (($# > 0)) || command_error "missing-backup-id command=$COMMAND"
      BACKUP_REFERENCE=$1
      shift
      while (($# > 0)); do
        case "$1" in
          --from)
            (($# >= 2)) || command_error "missing-value option=--from"
            SELECTED_DESTINATION=$2
            shift 2
            ;;
          --reason)
            [[ $COMMAND == pin ]] || command_error "option-not-supported command=unpin option=--reason"
            (($# >= 2)) || command_error "missing-value option=--reason"
            PIN_REASON=$2
            shift 2
            ;;
          -n|--dry-run)
            command_error "dry-run-not-supported command=$COMMAND"
            ;;
          *) command_error "unknown-option command=$COMMAND value=$1" ;;
        esac
      done
      if [[ $COMMAND == pin ]]; then
        if ((${#PIN_REASON} > 200)) || [[ $PIN_REASON == *$'\n'* || $PIN_REASON == *$'\r'* || $PIN_REASON == *$'\t'* ]]; then
          command_error "pin-reason-must-be-one-line-and-at-most-200-characters"
        fi
      fi
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
    restore-compose)
      (($# > 0)) || command_error "missing-backup-id command=restore-compose"
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
          --to)
            (($# >= 2)) || command_error "missing-value option=--to"
            RESTORE_DIRECTORY=$2
            shift 2
            ;;
          --project-dir)
            (($# >= 2)) || command_error "missing-value option=--project-dir"
            COMPOSE_RESTORE_PROJECT_DIRECTORY=$2
            shift 2
            ;;
          --apply)
            COMPOSE_RESTORE_APPLY=true
            shift
            ;;
          --confirm)
            COMPOSE_RESTORE_CONFIRMED=true
            shift
            ;;
          -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
          *) command_error "unknown-option command=restore-compose value=$1" ;;
        esac
      done
      [[ -n $RESTORE_DIRECTORY ]] || command_error "restore-compose-requires-to"
      if [[ $COMPOSE_RESTORE_APPLY == true ]]; then
        [[ -n $COMPOSE_RESTORE_PROJECT_DIRECTORY ]] || command_error "restore-compose-apply-requires-project-dir"
        [[ $COMPOSE_RESTORE_CONFIRMED == true ]] || command_error "restore-compose-apply-requires-confirm"
        [[ $DRY_RUN == false ]] || command_error "restore-compose-apply-does-not-support-dry-run"
      elif [[ -n $COMPOSE_RESTORE_PROJECT_DIRECTORY || $COMPOSE_RESTORE_CONFIRMED == true ]]; then
        command_error "restore-compose-project-dir-and-confirm-require-apply"
      fi
      ;;
    verify|restore)
      if [[ $COMMAND == restore ]]; then
        local argument has_pick=false pick_seen=false
        for argument in "$@"; do
          [[ $argument == --pick ]] && has_pick=true
        done
        if [[ $has_pick == true ]]; then
          while (($# > 0)); do
            case "$1" in
              --pick)
                [[ $pick_seen == false ]] || command_error "duplicate-option command=restore option=--pick"
                RESTORE_PICK=true
                pick_seen=true
                shift
                ;;
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
              --to)
                (($# >= 2)) || command_error "missing-value option=--to"
                RESTORE_DIRECTORY=$2
                shift 2
                ;;
              -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
              --quick|--full)
                command_error "option-not-supported command=restore option=$1"
                ;;
              -*) command_error "unknown-option command=restore value=$1" ;;
              *) command_error "restore-pick-requires-either-id-or-pick" ;;
            esac
          done
          [[ $pick_seen == true ]] || command_error "restore-pick-requires-either-id-or-pick"
          [[ -n $RESTORE_DIRECTORY ]] || command_error "restore-requires-to"
          return 0
        fi
      fi
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

  if [[ ( $COMMAND == watchdog || $COMMAND == diff || $COMMAND == pin || $COMMAND == unpin ) && $DRY_RUN == true ]]; then
    command_error "dry-run-not-supported command=$COMMAND"
  fi

  if [[ $COMMAND == quick || $COMMAND == quick-compose ]]; then
    [[ $CONFIG_FILE_EXPLICIT == false ]] || command_error "$COMMAND-does-not-use-config"
    check_yq
    if [[ $COMMAND == quick ]]; then
      quick_command
    else
      quick_compose_command
    fi
    return
  fi

  validate_absolute_path config "$CONFIG_FILE"
  check_yq
  validate_config

  case "$COMMAND" in
    run|prune|restore|restore-compose|watchdog|doctor) initialize_notifications ;;
  esac

  case "$COMMAND" in
    run) run_command ;;
    doctor) doctor_command ;;
    list) list_command ;;
    status) status_command ;;
    watchdog) watchdog_command ;;
    diff) diff_command ;;
    pin) pin_command ;;
    unpin) unpin_command ;;
    verify) verify_command ;;
    restore)
      local restore_result restore_job
      if restore_command; then
        restore_result=0
      else
        restore_result=$?
      fi
      BACKFORT_EVENT_ID=${BACKUP_ID:-$BACKUP_REFERENCE}
      BACKFORT_EVENT_TARGET=$RESTORE_DIRECTORY
      BACKFORT_EVENT_STAGE=restore
      BACKFORT_EVENT_ERROR=''
      BACKFORT_EVENT_EXTRA=''
      BACKFORT_EVENT_JOB=${SELECTED_JOB:-}
      if [[ -n $BACKUP_ID ]] && restore_job=$(selected_metadata_value '.job // ""'); then
        BACKFORT_EVENT_JOB=$restore_job
      fi
      if ((restore_result != 0)); then
        BACKFORT_EVENT_ERROR='restore did not complete'
      fi
      bf_notify_result restore "$restore_result"
      return "$restore_result"
      ;;
    restore-compose)
      local compose_restore_result compose_restore_job
      if restore_compose_command; then
        compose_restore_result=0
      else
        compose_restore_result=$?
      fi
      BACKFORT_EVENT_ID=${BACKUP_ID:-$BACKUP_REFERENCE}
      BACKFORT_EVENT_TARGET=$RESTORE_DIRECTORY
      BACKFORT_EVENT_STAGE=compose-restore
      BACKFORT_EVENT_ERROR=''
      BACKFORT_EVENT_EXTRA=''
      BACKFORT_EVENT_JOB=${SELECTED_JOB:-}
      if [[ -n $BACKUP_ID ]] && compose_restore_job=$(selected_metadata_value '.job // ""'); then
        BACKFORT_EVENT_JOB=$compose_restore_job
      fi
      if ((compose_restore_result != 0)); then
        BACKFORT_EVENT_ERROR='compose restore did not complete'
      fi
      bf_notify_result restore "$compose_restore_result"
      return "$compose_restore_result"
      ;;
    delete) delete_period_command ;;
    prune)
      local prune_result
      if prune_command; then
        prune_result=0
      else
        prune_result=$?
      fi
      BACKFORT_EVENT_JOB=${SELECTED_JOB:-all}
      BACKFORT_EVENT_ID=$(IFS=,; printf '%s' "${PRUNE_DELETED_IDS[*]:-}")
      BACKFORT_EVENT_SIZE="${PRUNE_FREED_BYTES}B"
      BACKFORT_EVENT_STAGE=prune
      BACKFORT_EVENT_ERROR=''
      BACKFORT_EVENT_EXTRA=''
      bf_notify_result prune "$prune_result"
      return "$prune_result"
      ;;
  esac
}

main "$@"
