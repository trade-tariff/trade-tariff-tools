#!/usr/bin/env bash
# Verify Copilot has reviewed the PR and all Copilot review threads are resolved.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-copilot-review-gate.sh --repo <owner/name> --pr <number>

Exits 0 when Copilot has submitted at least one PR review and every Copilot
inline review thread is resolved. Exits 1 with a message on stderr otherwise.
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

owner="${repo%%/*}"
name="${repo#*/}"

if [[ -z "$owner" || -z "$name" || "$owner" == "$repo" ]]; then
  echo "Invalid repo (expected owner/name): $repo" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required." >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required." >&2
  exit 2
fi

# Copilot code review author logins (see GitHub Copilot code review docs).
COPILOT_REVIEW_JQ='[
  .reviews[]
  | select(
      .author.login == "copilot"
      or .author.login == "copilot-pull-request-reviewer"
      or .author.login == "github-copilot[bot]"
      or (.author.login | test("copilot"; "i"))
    )
] | length'

copilot_review_count="$(gh pr view "$pr" \
  --repo "$repo" \
  --json reviews \
  -q "$COPILOT_REVIEW_JQ")"

if [[ "${copilot_review_count:-0}" -lt 1 ]]; then
  echo "PR #$pr has not been reviewed by Copilot yet. Request a review from Copilot before auto-merge." >&2
  exit 1
fi

threads_file="$(mktemp)"
trap 'rm -f "$threads_file"' EXIT

cursor=""
while true; do
  if [[ -n "$cursor" ]]; then
    response="$(gh api graphql \
      -f query='query($owner: String!, $repo: String!, $pr: Int!, $cursor: String!) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $pr) {
            reviewThreads(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                isResolved
                isOutdated
                path
                comments(first: 50) {
                  nodes { author { login } }
                }
              }
            }
          }
        }
      }' \
      -f owner="$owner" \
      -f repo="$name" \
      -F pr="$pr" \
      -f cursor="$cursor")"
  else
    response="$(gh api graphql \
      -f query='query($owner: String!, $repo: String!, $pr: Int!) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $pr) {
            reviewThreads(first: 100) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                isResolved
                isOutdated
                path
                comments(first: 50) {
                  nodes { author { login } }
                }
              }
            }
          }
        }
      }' \
      -f owner="$owner" \
      -f repo="$name" \
      -F pr="$pr")"
  fi

  jq -c '.data.repository.pullRequest.reviewThreads.nodes[]?' <<< "$response" >> "$threads_file"

  has_next="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<< "$response")"
  if [[ "$has_next" != "true" ]]; then
    break
  fi
  cursor="$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor' <<< "$response")"
done

if [[ ! -s "$threads_file" ]]; then
  exit 0
fi

unresolved="$(jq -s '
  def copilot_login:
    . == "copilot"
    or . == "copilot-pull-request-reviewer"
    or . == "github-copilot[bot]"
    or test("copilot"; "i");
  [
    .[]
    | select(.isResolved == false)
    | select(any(.comments.nodes[]?; .author.login | copilot_login))
  ]
' "$threads_file")"

unresolved_count="$(jq 'length' <<< "$unresolved")"

if [[ "$unresolved_count" -gt 0 ]]; then
  echo "$unresolved_count unresolved Copilot review thread(s) on PR #$pr:" >&2
  jq -r '.[] | "  - \(.path // "(no path)")\(if .isOutdated then " [outdated]" else "" end)"' <<< "$unresolved" >&2
  exit 1
fi

exit 0
