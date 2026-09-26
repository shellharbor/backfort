#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

mode=""
message=""
signature=""
while (($# > 0)); do
  case "$1" in
    -S) mode=sign; shift ;;
    -V) mode=verify; shift ;;
    -m) message=$2; shift 2 ;;
    -x) signature=$2; shift 2 ;;
    -s|-P) shift 2 ;;
    -q) shift ;;
    *) exit 64 ;;
  esac
done

[[ -n $mode && -n $message && -n $signature ]] || exit 64
case "$mode" in
  sign) sha256sum "$message" | awk '{print $1}' >"$signature" ;;
  verify) [[ $(sha256sum "$message" | awk '{print $1}') == $(<"$signature") ]] ;;
esac
