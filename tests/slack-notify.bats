#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  script="$repo_root/.github/actions/slack-notify/send-slack-notification.sh"

  cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
previous=""
for arg in "$@"; do
  if [[ "$previous" == "-d" ]]; then
    printf '%s' "$arg" > "$TEST_CAPTURE_DIR/payload.json"
  fi
  previous="$arg"
done
printf '%s\n' "${@: -1}" > "$TEST_CAPTURE_DIR/url.txt"
printf '%s' "${SLACK_RESPONSE:-ok}"
STUB
  chmod +x "$stub_bin/curl"
}

teardown() {
  rm -rf "$tmpdir"
}

run_notify() {
  run env \
    GITHUB_REPOSITORY="trade-tariff/example" \
    GITHUB_SERVER_URL="https://github.com" \
    GITHUB_RUN_ID="123" \
    GITHUB_ACTOR="octocat" \
    CHANNEL="deployments" \
    USERNAME="Deploy Bot" \
    ICON_EMOJI=":robot_face:" \
    TITLE="Deploy" \
    "$@" \
    "$script"
}

payload_field() {
  jq -r "$1" "$tmpdir/payload.json"
}

@test "skips when no webhook is set" {
  run_notify WEBHOOK="" COLOR="good" MESSAGE="hello"

  [ "$status" -eq 0 ]
  assert_contains "$output" "::notice::Skipping Slack notification because no webhook was provided"
  [ ! -f "$tmpdir/payload.json" ]
}

@test "posts the payload to the webhook" {
  run_notify WEBHOOK="https://hooks.slack.test/abc" COLOR="failure" MESSAGE="Deploy failed"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/url.txt")" = "https://hooks.slack.test/abc" ]
  [ "$(payload_field '.channel')" = "deployments" ]
  [ "$(payload_field '.username')" = "Deploy Bot" ]
  [ "$(payload_field '.icon_emoji')" = ":robot_face:" ]
  [ "$(payload_field '.attachments[0].color')" = "danger" ]
  [ "$(payload_field '.attachments[0].title')" = "Deploy" ]
  [ "$(payload_field '.attachments[0].text')" = "Deploy failed" ]
  [ "$(payload_field '.attachments[0].fallback')" = "Deploy: Deploy failed" ]
  [ "$(payload_field '.attachments[0].author_name')" = "octocat" ]
  [ "$(payload_field '.attachments[0].author_link')" = "https://github.com/octocat" ]
  [ "$(payload_field '.attachments[0].author_icon')" = "https://github.com/octocat.png?size=32" ]
  [ "$(payload_field '.attachments[0].footer')" = "trade-tariff/example | <https://github.com/trade-tariff/example/actions/runs/123|View workflow run>" ]
}

@test "maps colour names" {
  run_notify WEBHOOK="https://hooks.slack.test/abc" COLOR="success" MESSAGE="m"
  [ "$(payload_field '.attachments[0].color')" = "good" ]

  run_notify WEBHOOK="https://hooks.slack.test/abc" COLOR="cancelled" MESSAGE="m"
  [ "$(payload_field '.attachments[0].color')" = "#808080" ]

  run_notify WEBHOOK="https://hooks.slack.test/abc" COLOR="#123456" MESSAGE="m"
  [ "$(payload_field '.attachments[0].color')" = "#123456" ]
}

@test "posts when message is empty" {
  run_notify WEBHOOK="https://hooks.slack.test/abc" COLOR="good" MESSAGE=""

  [ "$status" -eq 0 ]
  [ -f "$tmpdir/payload.json" ]
  [ "$(payload_field '.attachments[0].text')" = "" ]
}

@test "warns but does not fail when Slack rejects the message" {
  run_notify SLACK_RESPONSE="invalid_payload" WEBHOOK="https://hooks.slack.test/abc" COLOR="good" MESSAGE="m"

  [ "$status" -eq 0 ]
  assert_contains "$output" "::warning::Slack notification failed: invalid_payload"
}

@test "requires runner environment when posting" {
  # -u is necessary: the CI runner sets GITHUB_RUN_ID in the test environment.
  run env -u GITHUB_RUN_ID WEBHOOK="https://hooks.slack.test/abc" MESSAGE="m" GITHUB_REPOSITORY="trade-tariff/example" GITHUB_SERVER_URL="https://github.com" GITHUB_ACTOR="octocat" "$script"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: GITHUB_RUN_ID"
}

@test "keeps an explicitly empty colour" {
  run_notify WEBHOOK="https://hooks.slack.test/abc" COLOR="" MESSAGE="m"

  [ "$status" -eq 0 ]
  [ "$(payload_field '.attachments[0].color')" = "" ]
}

@test "uses defaults when optional inputs are unset" {
  run env -u CHANNEL -u USERNAME -u ICON_EMOJI -u COLOR \
    WEBHOOK="https://hooks.slack.test/abc" MESSAGE="m" \
    GITHUB_REPOSITORY="trade-tariff/example" GITHUB_SERVER_URL="https://github.com" GITHUB_RUN_ID="123" GITHUB_ACTOR="octocat" \
    "$script"

  [ "$status" -eq 0 ]
  [ "$(payload_field '.channel')" = "deployments" ]
  [ "$(payload_field '.username')" = "Deploy Bot" ]
  [ "$(payload_field '.icon_emoji')" = ":robot_face:" ]
  [ "$(payload_field '.attachments[0].color')" = "good" ]
}

@test "prints help" {
  run "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: send-slack-notification.sh"
}

@test "slack-notify action delegates to the script" {
  action="$repo_root/.github/actions/slack-notify/action.yml"

  run grep -F "run: '\"\${{ github.action_path }}/send-slack-notification.sh\"'" "$action"
  [ "$status" -eq 0 ]
  run grep -F 'MESSAGE: ${{ inputs.message }}' "$action"
  [ "$status" -eq 0 ]
  run grep -F 'WEBHOOK: ${{ inputs.webhook }}' "$action"
  [ "$status" -eq 0 ]
}
