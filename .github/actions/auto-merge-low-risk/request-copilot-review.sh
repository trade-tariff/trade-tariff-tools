#!/usr/bin/env bash
# Request Copilot review unless an outstanding Copilot request already exists.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: request-copilot-review.sh --repo <owner/name> --pr <number>
EOF
}

repo=""
pr=""

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

if [[ -z "$repo" || -z "$pr" ]]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 2
fi

pending="$(gh pr view "$pr" \
  --repo "$repo" \
  --json reviewRequests \
  -q '[
    .reviewRequests[]?
    | select(
        .login == "copilot"
        or .login == "copilot-pull-request-reviewer"
        or .login == "copilot-pull-request-reviewer[bot]"
        or .login == "github-copilot[bot]"
      )
  ] | length')"

if [[ "${pending:-0}" -gt 0 ]]; then
  echo "Copilot review already requested on PR #$pr."
  exit 0
fi

echo "Requesting Copilot code review for PR #$pr"
if ! gh pr edit "$pr" --repo "$repo" --add-reviewer copilot-pull-request-reviewer; then
  echo "::warning::Unable to request Copilot code review for PR #$pr; auto-merge will retry after a review is available."
fi
