#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

latest_run_number() {
  local workflow_file

  workflow_file="$(basename "${WORKFLOW_REF%%@*}")"

  gh api "repos/${REPO}/actions/workflows/${workflow_file}/runs?per_page=1" \
    --jq '.workflow_runs[0].run_number // empty' 2>/dev/null || true
}

superseded="false"

# A failed lookup keeps the notification, so nobody misses a stopped deploy.
if [[ "$RESULT" == "cancelled" || "$RESULT" == "skipped" ]]; then
  latest="$(latest_run_number)"

  if [[ "$latest" =~ ^[0-9]+$ ]] && ((latest > RUN_NUMBER)); then
    superseded="true"
  fi
fi

echo "superseded=${superseded}" >> "$GITHUB_OUTPUT"
