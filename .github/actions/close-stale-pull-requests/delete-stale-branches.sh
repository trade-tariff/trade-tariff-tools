#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: delete-stale-branches.sh

Delete branches whose last commit is older than STALE_DAYS days. The default
branch, protected branches, and branches with an open pull request are kept.

Environment:
  REPO        (required) Repository as owner/name.
  STALE_DAYS  (required) Minimum age in days of the last commit.
  DRY_RUN     (required) "true" lists branches only. Other values delete them.
  GH_TOKEN    (optional) Token for the gh CLI. Not needed after gh auth login.

Exit codes:
  0  Success.
  1  A gh command failed.
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

for required_name in REPO STALE_DAYS DRY_RUN; do
  if [[ -z "${!required_name:-}" ]]; then
    echo "Missing required environment variable: $required_name" >&2
    usage >&2
    exit 2
  fi
done

stale_seconds=$((STALE_DAYS * 86400))
now=$(date -u +%s)
deleted=0
skipped_default=0
skipped_protected=0
skipped_open_pr=0
skipped_fresh=0

echo "Repository: ${REPO}"
echo "Branch stale threshold: ${STALE_DAYS} days"
echo "Dry run: ${DRY_RUN}"

default_branch=$(gh repo view "${REPO}" --json defaultBranchRef --jq '.defaultBranchRef.name')

declare -A open_pr_branches=()
while IFS= read -r branch_name; do
  [[ -n "${branch_name}" ]] || continue
  open_pr_branches["${branch_name}"]=1
done < <(gh pr list --repo "${REPO}" --state open --json headRefName --limit 500 --jq '.[].headRefName')

mapfile -t branches < <(gh api "repos/${REPO}/branches" --paginate --jq '.[] | @json')

if [[ ${#branches[@]} -eq 0 ]]; then
  echo "No branches."
  exit 0
fi

for branch_json in "${branches[@]}"; do
  name=$(jq -r '.name' <<<"${branch_json}")
  protected=$(jq -r '.protected' <<<"${branch_json}")
  sha=$(jq -r '.commit.sha' <<<"${branch_json}")

  if [[ "${name}" == "${default_branch}" ]]; then
    echo "Skipping branch ${name} (default branch)"
    skipped_default=$((skipped_default + 1))
    continue
  fi

  if [[ "${protected}" == "true" ]]; then
    echo "Skipping branch ${name} (protected)"
    skipped_protected=$((skipped_protected + 1))
    continue
  fi

  if [[ -n "${open_pr_branches[${name}]+x}" ]]; then
    echo "Skipping branch ${name} (open pull request)"
    skipped_open_pr=$((skipped_open_pr + 1))
    continue
  fi

  commit_json=$(gh api "repos/${REPO}/commits/${sha}")
  committed_at=$(jq -r '.commit.committer.date // .commit.author.date' <<<"${commit_json}")
  committed_epoch=$(date -u -d "${committed_at}" +%s)
  age=$((now - committed_epoch))

  if (( age < stale_seconds )); then
    skipped_fresh=$((skipped_fresh + 1))
    continue
  fi

  age_days=$((age / 86400))

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY RUN] Would delete branch ${name} (last commit ${committed_at}, ${age_days} days old)"
  else
    gh api --method DELETE "repos/${REPO}/git/refs/heads/${name}"
    echo "Deleted branch ${name}"
    deleted=$((deleted + 1))
  fi
done

echo "Summary: deleted=${deleted}, skipped_default=${skipped_default}, skipped_protected=${skipped_protected}, skipped_open_pr=${skipped_open_pr}, skipped_fresh=${skipped_fresh}"
