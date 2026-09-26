#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

: "${BACKFORT_FAKE_AGE_LOG:?missing BACKFORT_FAKE_AGE_LOG}"

mode=""
output=""
input=""
while (($# > 0)); do
  case "$1" in
    --encrypt) mode=encrypt; shift ;;
    --decrypt) mode=decrypt; shift ;;
    --recipient)
      printf 'recipient %s\n' "$2" >>"$BACKFORT_FAKE_AGE_LOG"
      shift 2
      ;;
    --identity) shift 2 ;;
    --output) output=$2; shift 2 ;;
    *) input=$1; shift ;;
  esac
done

[[ -n $mode && -n $output && -n $input ]] || exit 64
cp -- "$input" "$output"
printf '%s\n' "$mode" >>"$BACKFORT_FAKE_AGE_LOG"
