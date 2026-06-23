#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

fallback="Deploy to ${ENVIRONMENT} ${RESULT}"

append_message_output() {
  local message="$1"

  {
    echo 'message<<NOTIFY_EOF'
    echo "$message"
    echo 'NOTIFY_EOF'
  } >> "$GITHUB_OUTPUT"
}

gh_api() {
  gh api "$@" 2>/dev/null || true
}

fetch_pr() {
  local number="$1"

  if [[ -z "$number" ]]; then
    return 0
  fi

  gh_api "repos/${REPO}/pulls/${number}"
}

commit_title() {
  local ref="$1"

  if [[ -z "$ref" ]]; then
    return 0
  fi

  gh_api "repos/${REPO}/commits/${ref}" --jq '.commit.message | split("\n")[0] // empty'
}

pull_request_number_from_title() {
  local title="$1"

  if [[ "$title" =~ ^Merge\ pull\ request\ \#([0-9]+)\  ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$title" =~ \(\#([0-9]+)\)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
}

associated_pr() {
  local ref="$1"

  if [[ -z "$ref" ]]; then
    return 0
  fi

  # shellcheck disable=SC2016
  gh_api "repos/${REPO}/commits/${ref}/pulls" \
    -H "Accept: application/vnd.github+json" \
    --jq 'map(select(.merged_at != null)) as $merged | (($merged + .) | .[0]) // empty'
}

find_pr_data_for_ref() {
  local ref="$1"
  local title number pr_data

  title="$(commit_title "$ref")"
  number="$(pull_request_number_from_title "$title")"
  pr_data="$(fetch_pr "$number")"

  if [[ -n "$pr_data" ]]; then
    printf '%s\n' "$pr_data"
    return 0
  fi

  associated_pr "$ref"
}

find_pr_data() {
  local pr_data ref seen_refs
  seen_refs=" "

  pr_data="$(fetch_pr "${PR_NUMBER:-}")"
  if [[ -n "$pr_data" ]]; then
    printf '%s\n' "$pr_data"
    return 0
  fi

  for ref in "${TRIGGER_SHA:-}" "${DEPLOY_SHA:-}" "${SHA:-}"; do
    if [[ -z "$ref" || "$seen_refs" == *" $ref "* ]]; then
      continue
    fi

    seen_refs="${seen_refs}${ref} "
    pr_data="$(find_pr_data_for_ref "$ref")"

    if [[ -n "$pr_data" ]]; then
      printf '%s\n' "$pr_data"
      return 0
    fi
  done
}

pr_data="$(find_pr_data)"

if [[ -z "$pr_data" ]]; then
  append_message_output "$fallback"
  exit 0
fi

pr_title="$(echo "$pr_data" | jq -r '.title')"
pr_number="$(echo "$pr_data" | jq -r '.number')"
pr_url="$(echo "$pr_data" | jq -r '.html_url')"
risk_label="$(echo "$pr_data" | jq -r '[.labels[].name | select(test("risk"))] | .[0] // empty')"

message="${fallback}"$'\n'"*<${pr_url}|#${pr_number} — ${pr_title}>*"

if [[ -n "$risk_label" ]]; then
  case "$risk_label" in
    low-risk)    risk_emoji=":large_green_circle:" ;;
    medium-risk) risk_emoji=":large_yellow_circle:" ;;
    high-risk)   risk_emoji=":red_circle:" ;;
    *)           risk_emoji=":white_circle:" ;;
  esac
  message="${message}"$'\n'"Risk: ${risk_emoji} ${risk_label}"
fi

append_message_output "$message"
