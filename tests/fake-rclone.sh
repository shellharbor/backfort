#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REMOTE_ROOT=${BACKFORT_FAKE_RCLONE_ROOT:?BACKFORT_FAKE_RCLONE_ROOT is required}

remote_path() {
  local remote_object=$1
  local relative
  case "$remote_object" in
    fake:*)
      relative=${remote_object#fake:}
      printf '%s/%s\n' "$REMOTE_ROOT" "$relative"
      ;;
    failing:*)
      return 3
      ;;
    *)
      return 3
      ;;
  esac
}

command_name=${1:?missing rclone command}
shift

case "$command_name" in
  listremotes)
    printf 'fake:\nfailing:\n'
    ;;
  lsf)
    format=p
    while (($# > 1)); do
      case "$1" in
        --files-only) shift ;;
        --format)
          format=$2
          shift 2
          ;;
        *) shift ;;
      esac
    done
    local_path=$(remote_path "$1") || exit 1
    if [[ -n ${BACKFORT_FAKE_RCLONE_LOG:-} ]]; then
      printf 'lsf %s\n' "$1" >>"$BACKFORT_FAKE_RCLONE_LOG"
    fi
    if [[ -d $local_path ]]; then
      if [[ $format == s ]]; then
        find "$local_path" -maxdepth 1 -type f -printf '%s\n' | sort
      else
        find "$local_path" -maxdepth 1 -type f -printf '%f\n' | sort
      fi
    elif [[ -f $local_path ]]; then
      if [[ $format == s ]]; then
        wc -c <"$local_path" | tr -d '[:space:]'
        printf '\n'
      else
        basename -- "$local_path"
      fi
    fi
    ;;
  copyto)
    (($# == 2)) || exit 2
    source=$1
    target=$2
    if local_path=$(remote_path "$target"); then
      mkdir -p -- "$(dirname -- "$local_path")"
      cp -- "$source" "$local_path"
      if [[ -n ${BACKFORT_FAKE_RCLONE_LOG:-} ]]; then
        printf 'copyto %s\n' "${target##*/}" >>"$BACKFORT_FAKE_RCLONE_LOG"
      fi
    elif local_path=$(remote_path "$source"); then
      cp -- "$local_path" "$target"
    else
      exit 1
    fi
    ;;
  moveto)
    (($# == 2)) || exit 2
    source=$1
    target=$2
    source_path=$(remote_path "$source") || exit 1
    target_path=$(remote_path "$target") || exit 1
    mkdir -p -- "$(dirname -- "$target_path")"
    mv -f -- "$source_path" "$target_path"
    if [[ -n ${BACKFORT_FAKE_RCLONE_LOG:-} ]]; then
      printf 'moveto %s\n' "${target##*/}" >>"$BACKFORT_FAKE_RCLONE_LOG"
    fi
    ;;
  cat)
    (($# == 1)) || exit 2
    local_path=$(remote_path "$1") || exit 1
    cat -- "$local_path"
    ;;
  deletefile)
    (($# == 1)) || exit 2
    local_path=$(remote_path "$1") || exit 1
    rm -f -- "$local_path"
    ;;
  *)
    printf 'unsupported fake rclone command: %s\n' "$command_name" >&2
    exit 2
    ;;
esac
