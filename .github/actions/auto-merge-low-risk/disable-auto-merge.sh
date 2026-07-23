#!/usr/bin/env bash
# Disable any existing GitHub auto-merge request before evaluating fresh gates.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: disable-auto-merge.sh --repo <owner/name> --pr <number> --merge-method <merge|squash|rebase>
EOF
}

repo=""
pr=""
merge_method=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --pr)
      pr="$2"
      shift 2
      ;;
    --merge-method)
      merge_method="$2"
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

if [[ -z "$repo" || -z "$pr" || -z "$merge_method" ]]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 2
fi

case "$merge_method" in
  merge|squash|rebase) ;;
  *)
    echo "Invalid merge method: $merge_method (expected merge, squash, or rebase)." >&2
    exit 2
    ;;
esac

auto_merge_enabled="$(gh pr view "$pr" \
  --repo "$repo" \
  --json autoMergeRequest \
  -q '.autoMergeRequest != null')"

if [[ "$auto_merge_enabled" == "true" ]]; then
  echo "Disabling existing auto-merge for PR #$pr"
  gh pr merge "$pr" \
    --repo "$repo" \
    "--${merge_method}" \
    --disable-auto
else
  echo "No GitHub auto-merge request is running for PR #$pr; nothing to disable."
fi
