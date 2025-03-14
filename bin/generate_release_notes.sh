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
  "https://github.com/trade-tariff/trade-tariff-platform-aws-terraform.git"
  "https://github.com/trade-tariff/trade-tariff-platform-terraform-modules.git"
  "https://github.com/trade-tariff/trade-tariff-tech-docs.git"
  "https://github.com/trade-tariff/trade-tariff-fpo-dev-hub-e2e.git"
  "https://github.com/trade-tariff/trade-tariff-lambdas-fpo-search.git"
  "https://github.com/trade-tariff/trade-tariff-lambdas-fpo-model-garbage-collection"
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

function cached_fetch_author() {
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

    echo "$email,$author" >>"$cache_file"
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

    case "$release_type" in
      "continuous")
        echo "*$repo* (continuous deployment)"
        ;;
      "manual")
        echo "*$repo* (manual deployment)"
        ;;
      "n/a")
        echo "*$repo* (no deployment)"
        ;;
      *)
        echo "*$repo*"
        ;;
    esac

    echo "_<https://github.com/trade-tariff/$repo/commit/$sha1|${sha1}>_"
    echo

    while read -r line; do
      message=$(echo "$line" | awk -F\| '{print $1}')
      subject_line=$(echo "$line" | awk -F\| '{print $2}')
      email=$(echo "$line" | awk -F\| '{print $3}')
      username=$(cached_fetch_author "$email")
      pr_number=$(echo "$subject_line" | sed 's/^Merge pull request #\([0-9]*\).*$/\1/g')
      pr_link="https://github.com/trade-tariff/${repo}/pull/${pr_number}"

      echo "- <${pr_link}|${message}> by ${username}"
    done <<<"$merge_commits"

    echo
  fi
}

log_for() {
  local url=$1
  local repo=$2
  local release_type=$3
  local sha1=""

  cd "$repo" || exit

  sha1=$(curl --silent "$url" | jq '.git_sha1' | tr -d '"')
  merge_commits=$(git --no-pager log --merges HEAD..."$sha1" --format="format:%b|%s|%ae" --grep 'Merge pull request')

  print_merge_logs "$merge_commits" "$repo" "$sha1" "$release_type"

  cd ..
}

last_n_logs_for() {
  local repo=$1
  local release_type=$2
  local days=${3:-5}
  local sha1=""

  cd "$repo" || exit

  sha1=$(git rev-parse --short HEAD)
  merge_commits=$(git log --merges --since="$days days ago" --format="format:%b|%s|%ae" --grep 'Merge pull request')

  print_merge_logs "$merge_commits" "$repo" "$sha1" "$release_type"

  cd ..
}

all_logs() {
  log_for "https://www.trade-tariff.service.gov.uk/healthcheck" "trade-tariff-frontend" "manual"
  log_for "https://www.trade-tariff.service.gov.uk/api/v2/healthcheck" "trade-tariff-backend" "manual"
  log_for "https://www.trade-tariff.service.gov.uk/duty-calculator/healthcheck" "trade-tariff-duty-calculator" "manual"
  log_for "https://admin.trade-tariff.service.gov.uk/healthcheck" "trade-tariff-admin" "manual"
  last_n_logs_for "trade-tariff-api-docs" "continuous"
  last_n_logs_for "trade-tariff-platform-aws-terraform" "manual"
  last_n_logs_for "trade-tariff-platform-terraform-modules" "n/a"
  last_n_logs_for "trade-tariff-tech-docs" "continuous"
  last_n_logs_for "trade-tariff-fpo-dev-hub-e2e" "continuous"
  last_n_logs_for "trade-tariff-lambdas-fpo-search" "continuous"
  last_n_logs_for "trade-tariff-lambdas-fpo-model-garbage-collection" "continuous"
}

all_logs
fetch_and_present_deployers

rm -rf repos
