#!/usr/bin/env bash
set -euo pipefail

target="${1:-.}"
stack_arg="${2:-all}"
force="${3:-}"

if [[ "$stack_arg" == "--force" ]]; then
  stack_arg="all"
  force="--force"
fi
if [[ "$force" != "" && "$force" != "--force" ]]; then
  echo "Usage: $0 [target] [php,laravel,moodle,go|all] [--force]" >&2
  exit 2
fi

source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
mkdir -p "$target"
target_root="$(cd "$target" && pwd -P)"
if [[ "$source_root" == "$target_root" ]]; then
  echo "Target must be outside the AI Kit source." >&2
  exit 2
fi

selected=","
if [[ "$stack_arg" == "all" || -z "$stack_arg" ]]; then
  selected=",php,laravel,moodle,go,"
else
  IFS=',' read -r -a stacks <<< "$stack_arg"
  for raw in "${stacks[@]}"; do
    stack="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
    case "$stack" in
      php|laravel|moodle|go) selected+="$stack," ;;
      *) echo "Unknown stack '$stack'. Allowed: php, laravel, moodle, go." >&2; exit 2 ;;
    esac
  done
  if [[ "$selected" == *",laravel,"* || "$selected" == *",moodle,"* ]]; then
    [[ "$selected" == *",php,"* ]] || selected+="php,"
  fi
fi

files=()
for name in AGENTS.md CLAUDE.md AI_CONTEXT.md KIMI.md MANUS.md GEMINI.md .windsurfrules; do
  files+=("$source_root/$name")
done
while IFS= read -r -d '' file; do files+=("$file"); done < <(find "$source_root/.ai" "$source_root/.cursor" -type f -print0)
files+=("$source_root/.github/copilot-instructions.md")

copy_files=()
conflicts=()
for file in "${files[@]}"; do
  relative="${file#"$source_root"/}"
  if [[ "$relative" =~ ^\.ai/stacks/([^/]+)\.md$ ]]; then
    stack="${BASH_REMATCH[1]}"
    [[ "$selected" == *",$stack,"* ]] || continue
  fi
  destination="$target_root/$relative"
  copy_files+=("$file")
  if [[ -f "$destination" && "$force" != "--force" ]] && ! cmp -s "$file" "$destination"; then
    conflicts+=("$relative")
  fi
done

if (( ${#conflicts[@]} > 0 )); then
  echo "Refusing to overwrite existing files:" >&2
  printf ' - %s\n' "${conflicts[@]}" >&2
  echo "Re-run with --force after reviewing them." >&2
  exit 1
fi

for file in "${copy_files[@]}"; do
  relative="${file#"$source_root"/}"
  destination="$target_root/$relative"
  mkdir -p "$(dirname "$destination")"
  if [[ ! -f "$destination" || "$force" == "--force" ]]; then
    cp "$file" "$destination"
  fi
done

echo "AI Kit installed in $target_root"
echo "Next: fill .ai/project/repo-map.md and copy the required templates from .ai/templates/github/."

