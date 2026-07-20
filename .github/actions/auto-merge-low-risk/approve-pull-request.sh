#!/usr/bin/env bash
# Approve only the expected, currently ready pull request head.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: approve-pull-request.sh --repo <owner/name> --pr <number> --head <expected-oid>
EOF
}

repo=""
pr=""
expected_head=""

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
    --head)
      expected_head="$2"
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

if [[ -z "$repo" || -z "$pr" || -z "$expected_head" ]]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 2
fi

pull_request="$(gh pr view "$pr" \
  --repo "$repo" \
  --json headRefOid,isDraft)"
current_head="$(jq -r '.headRefOid' <<< "$pull_request")"

if [[ "$current_head" != "$expected_head" ]]; then
  echo "PR #$pr head changed from $expected_head to $current_head; refusing approval." >&2
  exit 1
fi

if [[ "$(jq -r '.isDraft' <<< "$pull_request")" == "true" ]]; then
  echo "PR #$pr is a draft; refusing approval." >&2
  exit 1
fi

gh api \
  --method POST \
  "repos/$repo/pulls/$pr/reviews" \
  -f event=APPROVE \
  -f commit_id="$expected_head"
