#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: cleanup-preview-environments.sh

Destroy preevy preview environments for trade-tariff-admin and
trade-tariff-frontend. An environment is kept when its ID contains "keep", or
when the open pull request for its branch has the keep-preview label. After a
destroy, the needs-preview label is removed from the pull request.

Environment:
  PREEVY_PROFILE_URL  (required) preevy profile URL, for example s3://preevy-profile-store?region=eu-west-2.
  DRY_RUN             (required) "true" lists environments only. Other values destroy them.
  RUN_MODE            (required) "scheduled" or "manual". Written to outputs for the report.
  GH_TOKEN            (optional) Token for the gh CLI. Not needed after gh auth login.

Outputs (to $GITHUB_OUTPUT, or stdout when unset):
  destroyed_envs  JSON array of environment IDs, with " (DRY RUN)" or " (FAILED)" suffixes.
  dry_run         The DRY_RUN value.
  run_mode        The RUN_MODE value.

Exit codes:
  0  Success, including when preevy cannot list environments.
  1  A command failed.
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

for required_name in PREEVY_PROFILE_URL DRY_RUN RUN_MODE; do
  if [[ -z "${!required_name:-}" ]]; then
    echo "Missing required environment variable: $required_name" >&2
    usage >&2
    exit 2
  fi
done

output_file="${GITHUB_OUTPUT:-/dev/stdout}"

write_outputs() {
  local destroyed_envs_json="$1"
  {
    echo "destroyed_envs=${destroyed_envs_json}"
    echo "dry_run=$DRY_RUN"
    echo "run_mode=$RUN_MODE"
  } >> "$output_file"
}

destroyed_envs="[]"

echo "Run mode: $RUN_MODE"
echo "Dry run: $DRY_RUN"

envs_json=$(preevy ls --json --profile "$PREEVY_PROFILE_URL") || {
  echo "⚠️ Failed to list environments"
  write_outputs "[]"
  exit 0
}

if [[ -z "$envs_json" || "$envs_json" == "null" ]]; then
  echo "⚠️ No environments found"
  write_outputs "[]"
  exit 0
fi

while IFS= read -r env_id; do
  [[ -z "$env_id" || "$env_id" == "null" ]] && continue
  [[ "$env_id" == *keep* ]] && {
    echo "🛑 Skipping (excluded by naming): $env_id"
    continue
  }

  # Environment ID format: trade-tariff-<admin|frontend>-<branch>
  env_repo=$(echo "$env_id" | sed -E 's/^trade-tariff-(admin|frontend)-.*$/\1/')
  branch_name=$(echo "$env_id" | sed -E 's/^trade-tariff-(admin|frontend)-//')
  branch_name="${branch_name,,}"

  should_skip="false"
  pr_number=""
  matching_repo="trade-tariff/trade-tariff-$env_repo"

  echo "🔍 Checking $matching_repo for branch: $branch_name"
  for pr in $(gh pr list --repo "$matching_repo" --state open --json number,headRefName -q '.[] | "\(.number)::\(.headRefName)"' || echo ""); do
    number="${pr%%::*}"
    head_branch="${pr##*::}"
    head_branch_lower="${head_branch,,}"

    if [[ "$head_branch_lower" == "$branch_name" ]]; then
      if gh pr view "$number" --repo "$matching_repo" --json labels -q '.labels[].name' | grep -q "^keep-preview$"; then
        echo "🛑 Skipping: $env_id (PR #$number in $matching_repo is labeled keep-preview)"
        should_skip="true"
      else
        pr_number="$number"
      fi
      break
    fi
  done

  if [[ "$should_skip" == "true" ]]; then
    continue
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "✅ [DRY RUN] Would destroy: $env_id"
    destroyed_envs=$(jq -n --argjson arr "$destroyed_envs" --arg id "$env_id" '$arr + [$id + " (DRY RUN)"]')
  else
    echo "🔥 Destroying: $env_id"
    if preevy down --id "$env_id" --force --wait --profile "$PREEVY_PROFILE_URL"; then
      destroyed_envs=$(jq -n --argjson arr "$destroyed_envs" --arg id "$env_id" '$arr + [$id]')
      if [[ -n "$pr_number" ]]; then
        echo "🏷️ Removing 'needs-preview' label from PR #$pr_number in $matching_repo"
        gh pr edit "$pr_number" --repo "$matching_repo" --remove-label "needs-preview" || echo "⚠️ Failed to remove label"
      fi
    else
      echo "❌ Failed to destroy: $env_id"
      destroyed_envs=$(jq -n --argjson arr "$destroyed_envs" --arg id "$env_id" '$arr + [$id + " (FAILED)"]')
    fi
  fi
done < <(echo "$envs_json" | jq -r '.[].envId')

write_outputs "$(jq -c <<< "$destroyed_envs")"
