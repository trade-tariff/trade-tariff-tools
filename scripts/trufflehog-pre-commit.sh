#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: docker is required to run the TruffleHog pre-commit scan." >&2
  exit 1
fi

scan_dir="${1:-$(pwd)}"
image="${TRUFFLEHOG_IMAGE:-trufflesecurity/trufflehog:latest}"

if [ ! -d "$scan_dir" ]; then
  echo "Error: scan directory does not exist: $scan_dir" >&2
  exit 1
fi

scan_dir="$(cd "$scan_dir" && pwd)"
exclude_file="$(mktemp)"
trap 'rm -f "$exclude_file"' EXIT

escape_regex() {
  printf '%s' "$1" | sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

append_gitignored_paths() {
  local git_root relative_prefix ignored_path relative_path escaped_path

  if ! git_root="$(git -C "$scan_dir" rev-parse --show-toplevel 2>/dev/null)"; then
    return 0
  fi

  git_root="$(cd "$git_root" && pwd)"

  case "$scan_dir/" in
    "$git_root/"*)
      relative_prefix="${scan_dir#"$git_root"/}"
      if [ "$scan_dir" = "$git_root" ]; then
        relative_prefix=""
      fi
      ;;
    *)
      return 0
      ;;
  esac

  while IFS= read -r ignored_path; do
    [ -n "$ignored_path" ] || continue

    if [ -n "$relative_prefix" ]; then
      case "$ignored_path" in
        "$relative_prefix"/*)
          relative_path="${ignored_path#"$relative_prefix"/}"
          ;;
        "$relative_prefix")
          relative_path='.'
          ;;
        *)
          continue
          ;;
      esac
    else
      relative_path="$ignored_path"
    fi

    [ "$relative_path" = "." ] && continue

    if [[ "$ignored_path" == */ ]]; then
      relative_path="${relative_path%/}"
      escaped_path="$(escape_regex "$relative_path")"
      printf '(^|/)%s(/|$)\n' "$escaped_path" >> "$exclude_file"
    else
      escaped_path="$(escape_regex "$relative_path")"
      printf '(^|/)%s$\n' "$escaped_path" >> "$exclude_file"
    fi
  done < <(git -C "$git_root" ls-files --others --ignored --exclude-standard --directory)
}

cat > "$exclude_file" <<'PATTERNS'
(^|/)\.git(/|$)
(^|/)\.terraform(/|$)
(^|/)\.terragrunt-cache(/|$)
PATTERNS

append_gitignored_paths

exec docker run --rm \
  -v "$scan_dir:/workdir:ro" \
  -v "$exclude_file:/trufflehog-exclude-paths.txt:ro" \
  -w /workdir \
  -i \
  "$image" \
  filesystem /workdir \
  --exclude-paths=/trufflehog-exclude-paths.txt \
  --results=verified,unknown \
  --fail
