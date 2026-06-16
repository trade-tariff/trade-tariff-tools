#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  script="$tmpdir/slack-notify.sh"
  payload_file="$tmpdir/payload.json"

  ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").fetch(0).fetch("run")' \
    "$repo_root/.github/actions/slack-notify/action.yml" > "$script"

  setup_stub_path
  cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

payload=""

while (($#)); do
  case "$1" in
    -d|--data|--data-raw|--data-binary)
      shift
      payload="$1"
      ;;
  esac
  shift || true
done

printf '%s' "$payload" > "$TEST_PAYLOAD_FILE"
printf 'ok'
STUB
  chmod +x "$stub_bin/curl"
}

teardown() {
  rm -rf "$tmpdir"
}

run_slack_notify() {
  TEST_PAYLOAD_FILE="$payload_file" env \
    WEBHOOK="https://hooks.slack.test/services/test" \
    CHANNEL="production-deployments" \
    USERNAME="Deploy Bot" \
    ICON_EMOJI=":robot_face:" \
    COLOR="success" \
    TITLE="Deploy to production" \
    MESSAGE='Deploy to production success\n*#258 - Bump govuk-components*' \
    GITHUB_REPOSITORY="trade-tariff/identity" \
    GITHUB_SERVER_URL="https://github.com" \
    GITHUB_RUN_ID="12345" \
    GITHUB_ACTOR="neilmiddleton" \
    bash "$script"
}

@test "slack-notify converts escaped newline sequences in message input" {
  run run_slack_notify

  [ "$status" -eq 0 ]

  text="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("attachments").fetch(0).fetch("text")' "$payload_file")"

  [[ "$text" == $'Deploy to production success\n*#258 - Bump govuk-components*' ]]
  [[ "$text" != *'\\n'* ]]
}
