#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-pr-lines.sh --threshold <n> --base <sha> --head <sha> [--base-ref <ref>] [--exclude-paths-file <file>]

Counts additions and deletions between two commits (after optional path exclusions)
and exits 1 when the total exceeds the threshold.
EOF
}

threshold=""
base_sha=""
head_sha=""
base_ref=""
exclude_paths_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold)
      threshold="$2"
      shift 2
      ;;
    --base)
      base_sha="$2"
      shift 2
      ;;
    --head)
      head_sha="$2"
      shift 2
      ;;
    --base-ref)
      base_ref="$2"
      shift 2
      ;;
    --exclude-paths-file)
      exclude_paths_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$threshold" || -z "$base_sha" || -z "$head_sha" ]]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 2
fi

if ! [[ "$threshold" =~ ^[0-9]+$ ]]; then
  echo "threshold must be a non-negative integer, got: $threshold" >&2
  exit 2
fi

merge_base_input="$base_sha"
if [[ -n "$base_ref" ]] && git rev-parse --verify --quiet "$base_ref" >/dev/null; then
  merge_base_input="$base_ref"
elif [[ -n "$base_ref" ]] && git rev-parse --verify --quiet "origin/$base_ref" >/dev/null; then
  merge_base_input="origin/$base_ref"
fi

merge_base="$(git merge-base "$merge_base_input" "$head_sha")"

exclude_specs=(
  ":(exclude)app/assets/builds/**"
  ":(exclude)public/assets/**"
  ":(exclude)vendor/javascript/**"
)
if [[ -n "$exclude_paths_file" && -f "$exclude_paths_file" ]]; then
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [[ -z "$pattern" || "$pattern" == \#* ]] && continue
    exclude_specs+=(":(exclude)${pattern}")
  done < "$exclude_paths_file"
fi

if ((${#exclude_specs[@]} > 0)); then
  numstat="$(git diff --numstat "$merge_base" "$head_sha" -- . "${exclude_specs[@]}")"
else
  numstat="$(git diff --numstat "$merge_base" "$head_sha" -- .)"
fi

total=0
if [[ -n "$numstat" ]]; then
  while IFS=$'\t' read -r added removed _file; do
    [[ -z "$added" || "$added" == "-" ]] && continue
    total=$((total + added + removed))
  done <<< "$numstat"
fi

echo "PR changes ${total} lines (threshold: ${threshold})"

{
  echo "## PR line count"
  echo ""
  echo "| Metric | Value |"
  echo "| --- | ---: |"
  echo "| Lines changed | ${total} |"
  echo "| Threshold | ${threshold} |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}" 2>/dev/null || true

if (( total > threshold )); then
  echo "::error::PR changes ${total} lines, which exceeds the limit of ${threshold}." >&2
  exit 1
fi
