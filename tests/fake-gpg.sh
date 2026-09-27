#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

mode=''
recipients=()
lookup=''
output=''
input=''

recipient_is_available() {
  local candidate=$1
  case ":${BACKFORT_FAKE_GPG_AVAILABLE_RECIPIENTS:-}:" in
    *":$candidate:"*) return 0 ;;
    *) return 1 ;;
  esac
}

while (($#)); do
  case "$1" in
    --list-keys)
      mode='list'
      lookup=${2:-}
      shift 2
      ;;
    --recipient)
      recipients+=("${2:-}")
      shift 2
      ;;
    --output)
      output=${2:-}
      shift 2
      ;;
    --passphrase-fd|--s2k-count)
      shift 2
      ;;
    --encrypt|--symmetric)
      mode='encrypt'
      shift
      ;;
    --decrypt)
      mode='decrypt'
      shift
      ;;
    --batch|--yes|--no-tty|--no-auto-key-retrieve|--trust-model|--with-colons|--pinentry-mode|--cipher-algo|--compress-algo|--s2k-mode|--s2k-digest-algo)
      shift
      ;;
    --*)
      printf 'unsupported fake gpg option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      input=$1
      shift
      ;;
  esac
done

case "$mode" in
  list)
    if ! recipient_is_available "$lookup"; then
      exit 2
    fi
    printf 'pub:::::::::\n'
    printf 'fpr:::::::::%s:\n' "$lookup"
    ;;
  encrypt)
    [[ -n $output && -n $input ]] || exit 2
    if ((${#recipients[@]})); then
      for recipient in "${recipients[@]}"; do
        recipient_is_available "$recipient" || exit 2
        printf 'encrypt recipient=%s\n' "$recipient" >>"$BACKFORT_FAKE_GPG_LOG"
      done
    else
      printf 'encrypt symmetric\n' >>"$BACKFORT_FAKE_GPG_LOG"
    fi
    cat -- "$input" >"$output"
    ;;
  decrypt)
    printf 'decrypt\n' >>"$BACKFORT_FAKE_GPG_LOG"
    cat
    ;;
  *)
    printf 'unsupported fake gpg invocation\n' >&2
    exit 2
    ;;
esac
