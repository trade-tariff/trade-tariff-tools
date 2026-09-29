#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  script="$repo_root/.github/actions/check-pr-lines/resolve-pull-request-shas.sh"
  output_file="$tmpdir/github-output"

  cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/curl-commands.txt"
if [[ -n "${CURL_FAIL:-}" ]]; then
  exit 22
fi
printf '%s' "${CURL_RESPONSE:-[]}"
STUB
  chmod +x "$stub_bin/curl"
}

teardown() {
  rm -rf "$tmpdir"
}

run_resolve() {
  run env GITHUB_OUTPUT="$output_file" "$@" "$script"
}

@test "explicit shas win over the event" {
  run_resolve INPUT_BASE_SHA="base1" INPUT_HEAD_SHA="head1" EVENT_NAME="push"

  [ "$status" -eq 0 ]
  outputs="$(cat "$output_file")"
  assert_contains "$outputs" "base_sha=base1"
  assert_contains "$outputs" "head_sha=head1"
  assert_contains "$outputs" "base_ref="
  assert_contains "$outputs" "skip=false"
  [ ! -f "$tmpdir/curl-commands.txt" ]
}

@test "pull_request uses the event shas" {
  run_resolve EVENT_NAME="pull_request" PR_BASE_SHA="base2" PR_HEAD_SHA="head2" PR_BASE_REF="main"

  [ "$status" -eq 0 ]
  outputs="$(cat "$output_file")"
  assert_contains "$outputs" "base_sha=base2"
  assert_contains "$outputs" "head_sha=head2"
  assert_contains "$outputs" "base_ref=main"
  assert_contains "$outputs" "skip=false"
}

@test "push looks up the open pull request" {
  run_resolve \
    CURL_RESPONSE='[{"base":{"sha":"base3","ref":"main"},"head":{"sha":"head3"}}]' \
    EVENT_NAME="push" REPOSITORY="trade-tariff/example" REPOSITORY_OWNER="trade-tariff" REF_NAME="feature" GITHUB_TOKEN="token"

  [ "$status" -eq 0 ]
  outputs="$(cat "$output_file")"
  assert_contains "$outputs" "base_sha=base3"
  assert_contains "$outputs" "head_sha=head3"
  assert_contains "$outputs" "base_ref=main"
  assert_contains "$outputs" "skip=false"
  curl_commands="$(cat "$tmpdir/curl-commands.txt")"
  assert_contains "$curl_commands" "https://api.github.com/repos/trade-tariff/example/pulls?head=trade-tariff:feature&state=open"
  assert_contains "$curl_commands" "Authorization: Bearer token"
}

@test "push without an open pull request skips" {
  run_resolve CURL_RESPONSE='[]' EVENT_NAME="push" REPOSITORY="trade-tariff/example" REPOSITORY_OWNER="trade-tariff" REF_NAME="feature" GITHUB_TOKEN="token"

  [ "$status" -eq 0 ]
  assert_contains "$output" "::notice::No open pull request for feature; skipping line check."
  assert_contains "$(cat "$output_file")" "skip=true"
}

@test "fails when the pull request lookup fails" {
  run_resolve CURL_FAIL=1 EVENT_NAME="push" REPOSITORY="trade-tariff/example" REPOSITORY_OWNER="trade-tariff" REF_NAME="feature" GITHUB_TOKEN="token"

  [ "$status" -ne 0 ]
  [ ! -f "$output_file" ] || assert_not_contains "$(cat "$output_file")" "skip="
}

@test "push requires repository details" {
  run_resolve EVENT_NAME="push" REPOSITORY="trade-tariff/example" REF_NAME="feature" GITHUB_TOKEN="token"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: REPOSITORY_OWNER"
}

@test "rejects an unsupported event" {
  run_resolve EVENT_NAME="workflow_dispatch"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Unsupported event: workflow_dispatch. Use pull_request or push."
}

@test "fails when shas cannot be determined" {
  run_resolve EVENT_NAME="pull_request"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Could not determine base-sha and head-sha."
}

@test "requires EVENT_NAME when shas are not given" {
  run env -u EVENT_NAME GITHUB_OUTPUT="$output_file" "$script"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: EVENT_NAME"
}

@test "prints help" {
  run "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: resolve-pull-request-shas.sh"
}

@test "check-pr-lines action resolves shas before it counts lines" {
  action="$repo_root/.github/actions/check-pr-lines/action.yml"

  run grep -F "run: '\"\${{ github.action_path }}/resolve-pull-request-shas.sh\"'" "$action"
  [ "$status" -eq 0 ]
  run grep -F "if: steps.resolve.outputs.skip != 'true'" "$action"
  [ "$status" -eq 0 ]
  run grep -F 'REF_NAME: ${{ github.ref_name }}' "$action"
  [ "$status" -eq 0 ]
  run grep -F 'BASE_SHA: ${{ steps.resolve.outputs.base_sha }}' "$action"
  [ "$status" -eq 0 ]
  run grep -F 'case "${{ github.event_name }}"' "$action"
  [ "$status" -ne 0 ]
  run grep -F '${{ github.ref_name }}&state=open' "$action"
  [ "$status" -ne 0 ]
}
