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
  "trade-tariff-frontend"
  "trade-tariff-backend"
  "trade-tariff-duty-calculator"
  "trade-tariff-admin"
  "trade-tariff-search-query-parser"
  "trade-tariff-api-docs"
  "trade-tariff-testing"
  "process-appendix-5a"
  "download-CDS-files"
  "trade-tariff-platform-aws-terraform"
  "trade-tariff-platform-terraform"
  "trade-tariff-platform-terraform-modules"
  "trade-tariff-platform-terraform-common"
  "trade-tariff-reporting"
  "trade-tariff-lambdas-fpo-search"
)

for repo in "${repos[@]}"; do
  git clone --quiet --depth 100 "https://github.com/trade-tariff/$repo.git"
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
  local pr_sha=$(curl -s -H "$auth_header" "https://api.github.com/repos/trade-tariff/$repo/pulls/$pr_number" | jq -r '.head.sha')

  local commit_status=$(curl -s -H "$auth_header" "https://api.github.com/repos/trade-tariff/$repo/commits/$pr_sha/status")

  if echo "$commit_status" | grep -q "API rate limit exceeded"; then
    echo ":question: Build"
  else
    local build_status=$(echo "$commit_status" | jq '.statuses')

    if [[ "$build_status" == "" || "$build_status" == "[]" ]]; then
      echo "No builds"
    else
      local unique_statuses=("$(echo "$build_status" | jq -r '.[].state' | sort -u)")

      if [[ "$unique_statuses" == "success" ]]; then
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

  local reviews=$(curl -s -H "$auth_header" "https://api.github.com/repos/trade-tariff/${repo}/pulls/${pr_number}/reviews")

  if echo "$reviews" | grep -q "API rate limit exceeded"; then
    echo ":question: approved"
  else
    local approved_reviews=$(echo "$reviews" | jq -r '.[] | select(.state == "APPROVED")' | jq -s)
    local changes_requested_reviews=$(echo "$reviews" | jq -r '.[] | select(.state == "CHANGES_REQUESTED" and .user.login != "dependabot[bot]")')
    local num_approved_reviews=$(echo "$approved_reviews" | jq -r 'map(.user.login) | unique | length')

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

  if [ "$merge_commits" != "" ]; then
    echo
    echo "*$repo*"
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

  print_merge_logs "$merge_commits" "$repo" "$sha1"

  cd ..
}

last_n_logs_for() {
  local repo=$1
  local days=$2
  local sha1=""

  cd "$repo" || exit

  sha1=$(git rev-parse --short HEAD)
  merge_commits=$(git log --merges --since="$days days ago" --format="format:%b|%s|%ae" --grep 'Merge pull request')

  print_merge_logs "$merge_commits" "$repo" "$sha1"

  cd ..
}

all_logs() {
  log_for "https://www.trade-tariff.service.gov.uk/healthcheck" "trade-tariff-frontend"
  log_for "https://www.trade-tariff.service.gov.uk/api/v2/healthcheck" "trade-tariff-backend"
  log_for "https://www.trade-tariff.service.gov.uk/duty-calculator/healthcheck" "trade-tariff-duty-calculator"
  log_for "https://tariff-admin-production.london.cloudapps.digital/healthcheck" "trade-tariff-admin"
  log_for "https://www.trade-tariff.service.gov.uk/api/search/healthcheck" "trade-tariff-search-query-parser"
  last_n_logs_for "trade-tariff-api-docs" 5
  last_n_logs_for "trade-tariff-testing" 5 # we don't release this
  last_n_logs_for "process-appendix-5a" 5 # we don't release this
  last_n_logs_for "download-CDS-files" 5 # we don't release this
  last_n_logs_for "trade-tariff-platform-aws-terraform" 5 # we don't release this
  last_n_logs_for "trade-tariff-platform-terraform" 5 # we don't release this
  last_n_logs_for "trade-tariff-platform-terraform-common" 5 # we don't release this
  last_n_logs_for "trade-tariff-platform-terraform-modules" 5 # we don't release this
  last_n_logs_for "trade-tariff-reporting" 5 # we don't release this
  last_n_logs_for "trade-tariff-lambdas-fpo-search" 5 # we don't release this
}

all_logs
fetch_and_present_deployers

rm -rf repos
