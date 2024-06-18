#!/usr/bin/env bash

set -o errexit
set -o nounset

webhook_url="$SLACK_WEBHOOK"
channel="#$SLACK_CHANNEL"
username="$SLACK_USERNAME"
message=$(bash bin/generate_release_notes.sh)
escaped_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | awk '{printf "%s\\n", $0}')
emoji=":robot_face:"
payload="{
  \"channel\": \"$channel\",
  \"text\": \"$escaped_message\",
  \"username\": \"$username\",
  \"icon_emoji\": \"$emoji\",
  \"mrkdwn\": true
}"

curl -X POST -H "Content-type: application/json" --data "$payload" "$webhook_url"
