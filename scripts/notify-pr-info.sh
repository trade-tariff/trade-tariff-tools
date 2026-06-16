#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

# Looks up the PR associated with a deployed commit and writes a composed
# Slack message to GITHUB_OUTPUT. Falls back to a plain message if the API
# call fails or no PR is found.
#
# Required env vars:
#   SHA         - the deployed commit SHA
#   REPO        - the GitHub repository (owner/name)
#   ENVIRONMENT - the deployment target (e.g. "production")
#   RESULT      - the deploy result (e.g. "success")
#   GITHUB_OUTPUT - path to the GitHub Actions output file

FALLBACK="Deploy to ${ENVIRONMENT} ${RESULT}"

PR_DATA=$(gh api "repos/${REPO}/commits/${SHA}/pulls" \
  -H "Accept: application/vnd.github+json" \
  --jq '.[0] // empty' 2>/dev/null || true)

if [[ -z "$PR_DATA" ]]; then
  echo "message=${FALLBACK}" >> "$GITHUB_OUTPUT"
  exit 0
fi

PR_TITLE=$(echo "$PR_DATA" | jq -r '.title')
PR_NUMBER=$(echo "$PR_DATA" | jq -r '.number')
PR_URL=$(echo "$PR_DATA" | jq -r '.html_url')
RISK_LABEL=$(echo "$PR_DATA" | jq -r '[.labels[].name | select(test("risk"))] | .[0] // empty')

MESSAGE="${FALLBACK}\n*<${PR_URL}|#${PR_NUMBER} — ${PR_TITLE}>*"

if [[ -n "$RISK_LABEL" ]]; then
  case "$RISK_LABEL" in
    low-risk)    RISK_EMOJI=":large_green_circle:" ;;
    medium-risk) RISK_EMOJI=":large_yellow_circle:" ;;
    high-risk)   RISK_EMOJI=":red_circle:" ;;
    *)           RISK_EMOJI=":white_circle:" ;;
  esac
  MESSAGE="${MESSAGE}\nRisk: ${RISK_EMOJI} ${RISK_LABEL}"
fi

echo "message=${MESSAGE}" >> "$GITHUB_OUTPUT"
