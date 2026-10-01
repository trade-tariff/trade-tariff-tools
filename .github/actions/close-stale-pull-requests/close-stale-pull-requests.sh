#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: close-stale-pull-requests.sh

Close open pull requests with no activity for STALE_DAYS days, and delete
their branches. Pull requests with the KEEP_LABEL label are not closed.

Environment:
  REPO        (required) Repository as owner/name.
  STALE_DAYS  (required) Minimum days with no activity.
  KEEP_LABEL  (required) Label that exempts a pull request.
  DRY_RUN     (required) "true" lists pull requests only. Other values close them.
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

for required_name in REPO STALE_DAYS KEEP_LABEL DRY_RUN; do
  if [[ -z "${!required_name:-}" ]]; then
    echo "Missing required environment variable: $required_name" >&2
    usage >&2
    exit 2
  fi
done

stale_seconds=$((STALE_DAYS * 86400))
now=$(date -u +%s)
closed=0
skipped_keep=0
skipped_fresh=0

echo "Repository: ${REPO}"
echo "Stale threshold: ${STALE_DAYS} days"
echo "Keep label: ${KEEP_LABEL}"
echo "Dry run: ${DRY_RUN}"

prs_json=$(gh pr list --repo "${REPO}" --state open --json number,updatedAt,labels --limit 500)
mapfile -t prs < <(jq -c '.[]' <<<"${prs_json}")

if [[ ${#prs[@]} -eq 0 ]]; then
  echo "No open pull requests."
  exit 0
fi

for pr_json in "${prs[@]}"; do
  number=$(jq -r '.number' <<<"${pr_json}")
  updated_at=$(jq -r '.updatedAt' <<<"${pr_json}")

  if jq -e --arg label "${KEEP_LABEL}" 'any(.labels[]; .name == $label)' <<<"${pr_json}" >/dev/null; then
    echo "Skipping PR #${number} (label: ${KEEP_LABEL})"
    skipped_keep=$((skipped_keep + 1))
    continue
  fi

  updated_epoch=$(date -u -d "${updated_at}" +%s)
  age=$((now - updated_epoch))

  if (( age < stale_seconds )); then
    skipped_fresh=$((skipped_fresh + 1))
    continue
  fi

  age_days=$((age / 86400))
  comment=$'Closing as stale: no activity for '"${age_days}"$' days (threshold: '"${STALE_DAYS}"$' days). Add the `'"${KEEP_LABEL}"$'` label to exempt a pull request from automatic closure.'

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "[DRY RUN] Would close PR #${number} (last updated ${updated_at})"
  else
    gh pr close "${number}" --repo "${REPO}" --comment "${comment}" --delete-branch
    echo "Closed PR #${number}"
    closed=$((closed + 1))
  fi
done

echo "Summary: closed=${closed}, skipped_keep=${skipped_keep}, skipped_fresh=${skipped_fresh}"
