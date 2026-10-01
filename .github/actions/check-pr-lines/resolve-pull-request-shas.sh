#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: resolve-pull-request-shas.sh

Find the base and head commit SHAs for the line count check. Explicit SHAs
win. Otherwise use the pull_request event, or look up the open pull request
for the pushed branch.

Environment:
  INPUT_BASE_SHA    (optional) Explicit base SHA.
  INPUT_HEAD_SHA    (optional) Explicit head SHA.
  EVENT_NAME        (required without both explicit SHAs) pull_request or push.
  PR_BASE_SHA       (pull_request) Base SHA from the event.
  PR_HEAD_SHA       (pull_request) Head SHA from the event.
  PR_BASE_REF       (pull_request) Base branch from the event.
  REPOSITORY        (push, required) Repository as owner/name.
  REPOSITORY_OWNER  (push, required) Repository owner.
  REF_NAME          (push, required) Pushed branch name.
  GITHUB_TOKEN      (push, required) Token for the GitHub API.

Outputs (to $GITHUB_OUTPUT, or stdout when unset):
  base_sha  Base commit SHA.
  head_sha  Head commit SHA.
  base_ref  Base branch name, or empty.
  skip      "true" when a push has no open pull request, else "false".

Exit codes:
  0  SHAs found, or the check is skipped.
  1  Unsupported event, API failure, or SHAs not found.
  2  Usage error.
EOF
}

case "${1:-}" in
  "")
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

output_file="${GITHUB_OUTPUT:-/dev/stdout}"

base_sha="${INPUT_BASE_SHA:-}"
head_sha="${INPUT_HEAD_SHA:-}"
base_ref=""
event_name="${EVENT_NAME:-}"

if [[ -z "$base_sha" || -z "$head_sha" ]]; then
  if [[ -z "$event_name" ]]; then
    echo "Missing required environment variable: EVENT_NAME" >&2
    usage >&2
    exit 2
  fi

  case "$event_name" in
    pull_request)
      base_sha="${PR_BASE_SHA:-}"
      head_sha="${PR_HEAD_SHA:-}"
      base_ref="${PR_BASE_REF:-}"
      ;;
    push)
      for required_name in REPOSITORY REPOSITORY_OWNER REF_NAME GITHUB_TOKEN; do
        if [[ -z "${!required_name:-}" ]]; then
          echo "Missing required environment variable: $required_name" >&2
          usage >&2
          exit 2
        fi
      done

      response="$(
        curl -fsSL \
          -H "Authorization: Bearer ${GITHUB_TOKEN}" \
          -H "Accept: application/vnd.github+json" \
          "https://api.github.com/repos/${REPOSITORY}/pulls?head=${REPOSITORY_OWNER}:${REF_NAME}&state=open"
      )"

      if [[ "$(jq 'length' <<< "$response")" -eq 0 ]]; then
        echo "::notice::No open pull request for ${REF_NAME}; skipping line check."
        {
          echo "base_sha="
          echo "head_sha="
          echo "base_ref="
          echo "skip=true"
        } >> "$output_file"
        exit 0
      fi

      base_sha="$(jq -r '.[0].base.sha' <<< "$response")"
      base_ref="$(jq -r '.[0].base.ref' <<< "$response")"
      head_sha="$(jq -r '.[0].head.sha' <<< "$response")"
      ;;
    *)
      echo "::error::Unsupported event: ${event_name}. Use pull_request or push." >&2
      exit 1
      ;;
  esac
fi

if [[ -z "$base_sha" || -z "$head_sha" ]]; then
  echo "::error::Could not determine base-sha and head-sha." >&2
  exit 1
fi

{
  echo "base_sha=${base_sha}"
  echo "head_sha=${head_sha}"
  echo "base_ref=${base_ref}"
  echo "skip=false"
} >> "$output_file"
