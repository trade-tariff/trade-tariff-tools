#!/usr/bin/env bash
# Verify Copilot has reviewed the PR and all Copilot review threads are resolved.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: check-copilot-review-gate.sh --repo <owner/name> --pr <number> [--head <expected-oid>]

Exits 0 when Copilot has reviewed the current PR head and every Copilot inline
review thread is resolved.
Exits 2 when Copilot has not reviewed the current PR head yet.
Exits 1 when a Copilot review requirement blocks auto-merge.
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
COPILOT_REVIEW_JQ='. as $pr
| def copilot_login:
    . == "copilot"
    or . == "copilot-pull-request-reviewer"
    or . == "copilot-pull-request-reviewer[bot]"
    or . == "github-copilot[bot]";
[
  .reviews[]?
  | select(.author.login | copilot_login)
  | select(.commit.oid == $pr.headRefOid)
] as $reviews
| [
    ($reviews | length),
    ($reviews
      | sort_by(.submittedAt // "")
      | last
      | (.body // "")
      | test("reached (their|the) (quota|budget) limit"; "i"))
  ]
| @tsv'

review_state="$(gh pr view "$pr" \
  --repo "$repo" \
  --json headRefOid,reviews)"
current_head="$(jq -r '.headRefOid' <<< "$review_state")"

if [[ -n "$expected_head" && "$current_head" != "$expected_head" ]]; then
  echo "PR #$pr head changed from $expected_head to $current_head; blocking auto-merge." >&2
  exit 1
fi

read -r copilot_review_count copilot_quota_exhausted <<< "$(jq -r "$COPILOT_REVIEW_JQ" <<< "$review_state")"

if [[ "$copilot_quota_exhausted" == "true" ]]; then
  echo "::warning::Copilot could not review PR #$pr because its review quota is exhausted; blocking auto-merge. GitHub reports that the user who requested the review has reached their quota or budget limit." >&2
  exit 1
fi

if [[ "${copilot_review_count:-0}" -lt 1 ]]; then
  echo "PR #$pr has not been reviewed by Copilot at its current head." >&2
  exit 2
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
      -f cursor="$cursor" 2>&1)" || {
      if grep -qi "resource not accessible by personal access token" <<< "$response"; then
        echo "::error::Insufficient token permissions to check Copilot review threads; blocking auto-merge." >&2
        exit 1
      fi
      echo "$response" >&2
      exit 1
    }
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
      -F pr="$pr" 2>&1)" || {
      if grep -qi "resource not accessible by personal access token" <<< "$response"; then
        echo "::error::Insufficient token permissions to check Copilot review threads; blocking auto-merge." >&2
        exit 1
      fi
      echo "$response" >&2
      exit 1
    }
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
    or . == "copilot-pull-request-reviewer[bot]"
    or . == "github-copilot[bot]";
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
