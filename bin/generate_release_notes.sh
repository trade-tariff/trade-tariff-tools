#!/usr/bin/env bash

set -o errexit
set -o nounset

source bin/fetch-deployers

if [ -d "repos" ]; then
  rm -rf repos
fi

GITHUB_TOKEN="${GITHUB_TOKEN:-}"

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Error: GITHUB_TOKEN environment variable not set"
  exit 1
fi

auth_header="Authorization: token $GITHUB_TOKEN"

mkdir repos

cd repos || exit 1

repos=(
  "https://github.com/trade-tariff/trade-tariff-frontend.git"
  "https://github.com/trade-tariff/trade-tariff-backend.git"
  "https://github.com/trade-tariff/trade-tariff-duty-calculator.git"
  "https://github.com/trade-tariff/trade-tariff-admin.git"
  "https://github.com/trade-tariff/trade-tariff-api-docs.git"
  "https://github.com/trade-tariff/trade-tariff-testing.git"
  "https://github.com/trade-tariff/process-appendix-5a.git"
  "https://github.com/trade-tariff/download-CDS-files.git"
  "https://github.com/trade-tariff/trade-tariff-platform-aws-terraform.git"
  "https://github.com/trade-tariff/trade-tariff-platform-terraform-modules.git"
  "https://github.com/trade-tariff/trade-tariff-reporting.git"
  "https://github.com/trade-tariff/trade-tariff-tech-docs.git"
  "https://github.com/trade-tariff/trade-tariff-fpo-dev-hub-e2e.git"
  "https://github.com/trade-tariff/trade-tariff-lambdas-fpo-search.git"
  "https://github.com/trade-tariff/trade-tariff-dev-hub-frontend.git"
  "https://github.com/trade-tariff/trade-tariff-dev-hub-backend.git"
  "https://github.com/trade-tariff/trade-tariff-lambdas-fpo-model-garbage-collection"
  "https://github.com/trade-tariff/trade-tariff-lambdas-database-replication"
  "https://github.com/trade-tariff/trade-tariff-commodi-tea"
)

for repo in "${repos[@]}"; do
  git clone --quiet --depth 100 "$repo"
done

if [ -f ".github_authors_cache" ]; then
  rm .github_authors_cache
  touch .github_authors_cache
else
  touch .github_authors_cache
fi

cache_file="$PWD/.github_authors_cache"

function fetch_build_status() {
  local repo="$1"
  local pr_number="$2"
  pr_sha=$(curl -s -H "$auth_header" "https://api.github.com/repos/trade-tariff/$repo/pulls/$pr_number" | jq -r '.head.sha')

  commit_status=$(curl -s -H "$auth_header" "https://api.github.com/repos/trade-tariff/$repo/commits/$pr_sha/status")

  if echo "$commit_status" | grep -q "API rate limit exceeded"; then
    echo ":question: Build"
  else
    build_status=$(echo "$commit_status" | jq '.statuses')

    if [[ "$build_status" == "" || "$build_status" == "[]" ]]; then
      echo "No builds"
    else
      unique_statuses=("$(echo "$build_status" | jq -r '.[].state' | sort -u)")

      if [[ "${unique_statuses[*]}" == "success" ]]; then
        echo ":white_check_mark: Build"
      else
        echo ":x: Build"
      fi
    fi
  fi
}

function fetch_approval_status() {
  local repo="$1"
  local pr_number="$2"

  reviews=$(curl -s -H "$auth_header" "https://api.github.com/repos/trade-tariff/${repo}/pulls/${pr_number}/reviews")

  if echo "$reviews" | grep -q "API rate limit exceeded"; then
    echo ":question: approved"
  else
    approved_reviews=$(echo "$reviews" | jq -r '.[] | select(.state == "APPROVED")' | jq -s)
    changes_requested_reviews=$(echo "$reviews" | jq -r '.[] | select(.state == "CHANGES_REQUESTED" and .user.login != "dependabot[bot]")')
    num_approved_reviews=$(echo "$approved_reviews" | jq -r 'map(.user.login) | unique | length')

    if [[ "$reviews" == "" || "$reviews" == "[]" ]]; then
      echo "No reviews"
    elif [[ "$approved_reviews" == "" ]]; then
      echo ":x: Not approved"
    elif [[ "$changes_requested_reviews" != "" ]]; then
      echo ":x: Changes requested"
    else
      echo ":white_check_mark: Approved (${num_approved_reviews})"
    fi
  fi
}

function check_pr_status() {
  local repo="$1"
  local pr_number="$2"

  build_status=$(fetch_build_status "$repo" "$pr_number")
  approval_status=$(fetch_approval_status "$repo" "$pr_number")

  echo "${build_status} ${approval_status}"
}

cachedFetchAuthor() {
  local email="$1"

  result=$(grep "^$email," "$cache_file")
  if [ "$result" != "" ]; then
    author=$(echo "$result" | awk -F, '{print $2}')
  else
    author=$(curl -s "https://api.github.com/search/users?q=$email+in:email" | jq -r '.items[0].login')

    if [ "$author" == "null" ]; then
      author="$email"
    else
      author="<https://github.com/$author|$author>"
    fi

    echo "$email,$author" >> "$cache_file"
  fi

  echo "$author"
}

function print_merge_logs() {
  local merge_commits=$1
  local repo=$2
  local sha1=$3
  local release_type=$4

  if [ "$merge_commits" != "" ]; then
    echo
    if [ "$release_type" == "continuous" ]; then
      echo "*$repo* (continuous deployment)"
    else
      echo "*$repo* (manual deployment)"
    fi
    echo

    echo "_<https://github.com/trade-tariff/$repo/commit/$sha1|${sha1}>_"
    echo

    while read -r line; do
      message=$(echo "$line" | awk -F\| '{print $1}')
      subject_line=$(echo "$line" | awk -F\| '{print $2}')
      email=$(echo "$line" | awk -F\| '{print $3}')
      username=$(cachedFetchAuthor "$email")
      pr_number=$(echo "$subject_line" | sed 's/^Merge pull request #\([0-9]*\).*$/\1/g')
      pr_link="https://github.com/trade-tariff/${repo}/pull/${pr_number}"
      # pr_status="$(check_pr_status "$repo" "$pr_number")"

      echo "- <${pr_link}|${message}> by ${username}"
    done <<< "$merge_commits"

    echo
  fi
}

log_for() {
  local url=$1
  local repo=$2
  local sha1=""

  cd "$repo" || exit

  sha1=$(curl --silent "$url" | jq '.git_sha1' | tr -d '"')
  merge_commits=$(git --no-pager log --merges HEAD..."$sha1" --format="format:%b|%s|%ae" --grep 'Merge pull request')

  print_merge_logs "$merge_commits" "$repo" "$sha1" "batched"

  cd ..
}

last_n_logs_for() {
  local repo=$1
  local days=${2:-5}
  local sha1=""

  cd "$repo" || exit

  sha1=$(git rev-parse --short HEAD)
  merge_commits=$(git log --merges --since="$days days ago" --format="format:%b|%s|%ae" --grep 'Merge pull request')

  print_merge_logs "$merge_commits" "$repo" "$sha1" "continuous"

  cd ..
}

all_logs() {
  log_for "https://www.trade-tariff.service.gov.uk/healthcheck" "trade-tariff-frontend"
  log_for "https://www.trade-tariff.service.gov.uk/api/v2/healthcheck" "trade-tariff-backend"
  log_for "https://www.trade-tariff.service.gov.uk/duty-calculator/healthcheck" "trade-tariff-duty-calculator"
  log_for "https://admin.trade-tariff.service.gov.uk/healthcheck" "trade-tariff-admin"
  last_n_logs_for "trade-tariff-api-docs"
  last_n_logs_for "trade-tariff-testing"
  last_n_logs_for "process-appendix-5a"
  last_n_logs_for "download-CDS-files"
  last_n_logs_for "trade-tariff-platform-aws-terraform"
  last_n_logs_for "trade-tariff-platform-terraform-modules"
  last_n_logs_for "trade-tariff-reporting"
  last_n_logs_for "trade-tariff-tech-docs"
  last_n_logs_for "trade-tariff-fpo-dev-hub-e2e"
  last_n_logs_for "trade-tariff-lambdas-fpo-search"
  last_n_logs_for "trade-tariff-lambdas-fpo-model-garbage-collection"
  last_n_logs_for "trade-tariff-dev-hub-frontend"
  last_n_logs_for "trade-tariff-dev-hub-backend"
  last_n_logs_for "trade-tariff-lambdas-database-replication"
  last_n_logs_for "trade-tariff-commodi-tea"
}

all_logs
fetch_and_present_deployers

rm -rf repos
