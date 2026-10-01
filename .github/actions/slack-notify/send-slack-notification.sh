#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: send-slack-notification.sh

Post a message with one attachment to a Slack incoming webhook.

Environment:
  WEBHOOK            (optional) Slack webhook URL. When empty, log a notice and exit 0.
  MESSAGE            (optional, default: empty) Message body in Slack mrkdwn.
  TITLE              (optional, default: empty) Message title.
  CHANNEL            (optional, default when unset: deployments) Slack channel.
  USERNAME           (optional, default when unset: Deploy Bot) Bot username.
  ICON_EMOJI         (optional, default when unset: :robot_face:) Bot icon.
  COLOR              (optional, default when unset: good) good, danger, warning, success,
                     failure, cancelled, or a hex code.
  GITHUB_REPOSITORY  (required when WEBHOOK is set) Set by the runner.
  GITHUB_SERVER_URL  (required when WEBHOOK is set) Set by the runner.
  GITHUB_RUN_ID      (required when WEBHOOK is set) Set by the runner.
  GITHUB_ACTOR       (required when WEBHOOK is set) Set by the runner.

Exit codes:
  0  Posted, skipped, or Slack returned an error (logged as a warning).
  1  curl failed.
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

webhook="${WEBHOOK:-}"

if [[ -z "$webhook" ]]; then
  echo "::notice::Skipping Slack notification because no webhook was provided"
  exit 0
fi

for required_name in GITHUB_REPOSITORY GITHUB_SERVER_URL GITHUB_RUN_ID GITHUB_ACTOR; do
  if [[ -z "${!required_name:-}" ]]; then
    echo "Missing required environment variable: $required_name" >&2
    usage >&2
    exit 2
  fi
done

message="${MESSAGE:-}"
title="${TITLE:-}"
channel="${CHANNEL-deployments}"
username="${USERNAME-Deploy Bot}"
icon_emoji="${ICON_EMOJI-:robot_face:}"
color="${COLOR-good}"

case "$color" in
  success) color="good" ;;
  failure) color="danger" ;;
  cancelled) color="#808080" ;;
esac

footer="${GITHUB_REPOSITORY} | <${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}|View workflow run>"

payload=$(jq -n \
  --arg channel "$channel" \
  --arg username "$username" \
  --arg icon_emoji "$icon_emoji" \
  --arg color "$color" \
  --arg title "$title" \
  --arg text "$message" \
  --arg footer "$footer" \
  --arg author_name "$GITHUB_ACTOR" \
  --arg author_link "${GITHUB_SERVER_URL}/${GITHUB_ACTOR}" \
  --arg author_icon "${GITHUB_SERVER_URL}/${GITHUB_ACTOR}.png?size=32" \
  --arg fallback "$title: $message" \
  '{
    channel: $channel,
    username: $username,
    icon_emoji: $icon_emoji,
    attachments: [{
      color: $color,
      author_name: $author_name,
      author_link: $author_link,
      author_icon: $author_icon,
      title: $title,
      text: $text,
      footer: $footer,
      fallback: $fallback
    }]
  }')

response=$(curl -sS -X POST \
  -H "Content-Type: application/json" \
  -d "$payload" \
  "$webhook")

if [[ "$response" != "ok" ]]; then
  echo "::warning::Slack notification failed: $response"
fi
