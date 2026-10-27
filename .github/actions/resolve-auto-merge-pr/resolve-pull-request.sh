#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: resolve-pull-request.sh [--help]
Resolve one internal pull request without matching branch names.

Arguments: -h, --help prints this help.
Environment:
  GITHUB_EVENT_NAME, GITHUB_EVENT_PATH, GITHUB_REPOSITORY are required.
  GH_TOKEN is required by gh for workflow_run lookups.
  GITHUB_OUTPUT is optional (defaults to stdout).
  TRACE is optional (enables tracing when non-empty).
Outputs: number=<PR number>, or number= when no unique eligible PR exists.
Exit codes: 0 success or safe skip, 1 GitHub/JSON failure, 2 usage error.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; exit 2 ;;
esac

for name in GITHUB_EVENT_NAME GITHUB_EVENT_PATH GITHUB_REPOSITORY; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 2
  fi
done

number=""
case "$GITHUB_EVENT_NAME" in
  pull_request|pull_request_review)
    number="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")"
    ;;
  workflow_run)
    if jq -e --arg repo "$GITHUB_REPOSITORY" '
      .workflow_run.conclusion == "success" and
      .workflow_run.head_repository.full_name == $repo
    ' "$GITHUB_EVENT_PATH" >/dev/null; then
      head_sha="$(jq -r '.workflow_run.head_sha // empty' "$GITHUB_EVENT_PATH")"
      associated="$(jq -c '.workflow_run.pull_requests // []' "$GITHUB_EVENT_PATH")"
      count="$(jq 'length' <<< "$associated")"
      candidates='[]'
      if [[ "$head_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
        if [[ "$count" -eq 1 ]]; then
          pr="$(jq -r '.[0].number' <<< "$associated")"
          if [[ "$pr" =~ ^[1-9][0-9]*$ ]]; then
            candidates="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$pr" --jq '[.]')"
          fi
        elif [[ "$count" -eq 0 ]]; then
          # Push CI (including backend Dependabot) can omit the PR association.
          # Commit associations are safe only after checking the exact PR head.
          candidates="$(gh api --paginate --slurp \
            "repos/$GITHUB_REPOSITORY/commits/$head_sha/pulls?per_page=100" \
            | jq 'add')"
        fi
        number="$(jq -r --arg repo "$GITHUB_REPOSITORY" --arg sha "$head_sha" '
          [.[] | select(.state == "open" and
            .base.repo.full_name == $repo and
            .head.repo.full_name == $repo and .head.sha == $sha)]
          | if length == 1 then .[0].number else empty end
        ' <<< "$candidates")"
      fi
    fi
    ;;
esac

if [[ -n "$number" && ! "$number" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid pull request number; refusing to resolve auto-merge." >&2
  exit 1
fi
printf 'number=%s\n' "$number" >> "${GITHUB_OUTPUT:-/dev/stdout}"
