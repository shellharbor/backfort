#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

: "${BACKFORT_FAKE_DOCKER_ROOT:?missing BACKFORT_FAKE_DOCKER_ROOT}"
: "${BACKFORT_FAKE_DOCKER_LOG:?missing BACKFORT_FAKE_DOCKER_LOG}"

log() {
  printf '%s\n' "$*" >>"$BACKFORT_FAKE_DOCKER_LOG"
}

container_file() {
  local container_id=$1
  local path=$2
  printf '%s/containers/%s%s\n' "$BACKFORT_FAKE_DOCKER_ROOT" "$container_id" "$path"
}

case "${1:-}" in
  image)
    [[ ${2:-} == inspect ]] || exit 64
    log 'image-inspect'
    exit 0
    ;;
  volume)
    [[ ${2:-} == inspect ]] || exit 64
    [[ -d "$BACKFORT_FAKE_DOCKER_ROOT/volumes/${3:-}" ]] || exit 1
    log "volume-inspect ${3:-}"
    exit 0
    ;;
  run)
    shift
    source_volume=""
    backup_directory=""
    while (($# > 0)); do
      case "$1" in
        -v)
          mount=$2
          shift 2
          case "$mount" in
            *:/source:ro) source_volume=${mount%:/source:ro} ;;
            *:/backup:rw) backup_directory=${mount%:/backup:rw} ;;
          esac
          ;;
        --cap-drop|--network)
          shift 2
          ;;
        --rm|--pull=never|--read-only)
          shift
          ;;
        *) break ;;
      esac
    done
    [[ -n $source_volume && -n $backup_directory && -d "$BACKFORT_FAKE_DOCKER_ROOT/volumes/$source_volume" ]] || exit 1
    tar --create --file "$backup_directory/data.tar" --directory "$BACKFORT_FAKE_DOCKER_ROOT/volumes/$source_volume" .
    log "volume-snapshot $source_volume"
    exit 0
    ;;
  cp)
    source=$2
    destination=$3
    container_id=${source%%:*}
    container_path=${source#*:}
    cp -- "$(container_file "$container_id" "$container_path")" "$destination"
    log "copy-from-container $container_id"
    exit 0
    ;;
  compose)
    shift
    while (($# > 0)); do
      case "$1" in
        --project-directory|-f) shift 2 ;;
        *) break ;;
      esac
    done
    command=${1:-}
    shift || true
    case "$command" in
      version)
        log 'compose-version'
        exit 0
        ;;
      config)
        case "${1:-}" in
          --quiet)
            log 'compose-config-quiet'
            exit 0
            ;;
          --services)
            printf '%s\n' postgres mysql mariadb mssql oracle app
            log 'compose-services'
            exit 0
            ;;
          --format)
            [[ ${2:-} == json ]] || exit 64
            printf '%s\n' '{"volumes":{"media":{"name":"fake_media"}}}'
            log 'compose-config-json'
            exit 0
            ;;
        esac
        exit 64
        ;;
      ps)
        [[ ${1:-} == -q ]] || exit 64
        printf 'fake-%s\n' "${2:-}"
        log "compose-ps ${2:-}"
        exit 0
        ;;
      exec)
        while (($# > 0)); do
          case "$1" in
            -T) shift ;;
            -e) shift 2 ;;
            *) break ;;
          esac
        done
        service=$1
        shift
        executable=$1
        shift
        case "$executable" in
          pg_dump)
            format=custom
            for argument in "$@"; do
              if [[ $argument == --format=plain ]]; then
                format=plain
                break
              fi
            done
            if [[ $format == plain ]]; then
              printf 'postgres plain SQL dump for %s\n' "$service"
            else
              printf 'postgres custom dump for %s\n' "$service"
            fi
            ;;
          pg_dumpall)
            printf 'postgres globals for %s\n' "$service"
            ;;
          mysqldump|mariadb-dump)
            printf 'mysql logical dump for %s\n' "$service"
            ;;
          pg_restore|psql|mysql|mariadb)
            cat >/dev/null
            log "compose-restore $service $executable"
            ;;
          sqlcmd)
            query=""
            while (($# > 0)); do
              if [[ $1 == -Q ]]; then
                query=$2
                break
              fi
              shift
            done
            [[ $query =~ N\'([^\']+)\' ]] || exit 1
            path=${BASH_REMATCH[1]}
            target=$(container_file "fake-$service" "$path")
            mkdir -p -- "$(dirname -- "$target")"
            printf 'mssql native backup\n' >"$target"
            ;;
          sh)
            arguments=("$@")
            argument_count=${#arguments[@]}
            ((argument_count >= 5)) || exit 64
            dumpfile=${arguments[$((argument_count - 2))]}
            logfile=${arguments[$((argument_count - 1))]}
            directory_name=${arguments[$((argument_count - 3))]}
            case "$directory_name" in
              DATA_PUMP_DIR) directory='/opt/oracle/admin/FREE/dpdump' ;;
              *) exit 64 ;;
            esac
            dump_target=$(container_file "fake-$service" "$directory/$dumpfile")
            log_target=$(container_file "fake-$service" "$directory/$logfile")
            mkdir -p -- "$(dirname -- "$dump_target")"
            printf 'oracle data pump export\n' >"$dump_target"
            printf 'oracle export log\n' >"$log_target"
            ;;
          rm)
            while (($# > 0)); do
              case "$1" in
                -f|--) shift ;;
                /*) rm -f -- "$(container_file "fake-$service" "$1")"; shift ;;
                *) shift ;;
              esac
            done
            ;;
          *) exit 64 ;;
        esac
        log "compose-exec $service $executable"
        exit 0
        ;;
    esac
    exit 64
    ;;
  *) exit 64 ;;
esac
