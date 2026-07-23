#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
  export GITHUB_OUTPUT="$tmpdir/github_output"
  touch "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$tmpdir"
}

make_gh_stub() {
  local response="$1"
  cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' '${response}'
STUB
  chmod +x "$stub_bin/gh"
}

run_script() {
  run env \
    DEPLOY_SHA="${DEPLOY_SHA:-abc1234}" \
    PR_NUMBER="${PR_NUMBER:-}" \
    REPO="trade-tariff/example" \
    SHA="${SHA:-abc1234}" \
    TRIGGER_SHA="${TRIGGER_SHA:-}" \
    ENVIRONMENT="production" \
    RESULT="success" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" \
    "$repo_root/scripts/deploy-pr-info.sh"
}

@test "outputs a plain fallback message when the API returns no PR" {
  make_gh_stub ""

  run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "Deploy to production success"
}

@test "uses an explicit pull request number when the triggering event provides one" {
  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "repos/trade-tariff/example/pulls/123" ]]; then
  printf '%s\n' '{"number":123,"title":"Triggered PR","html_url":"https://github.com/trade-tariff/example/pull/123","labels":[]}'
fi
STUB
  chmod +x "$stub_bin/gh"

  PR_NUMBER="123" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "#123 — Triggered PR"
}

@test "uses the trigger commit title before the deployed app commit" {
  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" != "api" ]]; then
  exit 1
fi

case "$2" in
  repos/trade-tariff/example/commits/trigger-sha)
    printf '%s\n' 'Merge pull request #456 from trade-tariff/HMRC-456-real-change'
    ;;
  repos/trade-tariff/example/pulls/456)
    printf '%s\n' '{"number":456,"title":"Real triggering PR","html_url":"https://github.com/trade-tariff/example/pull/456","labels":[]}'
    ;;
  repos/trade-tariff/example/commits/deploy-sha)
    printf '%s\n' 'Merge pull request #232 from trade-tariff/dependabot/faraday'
    ;;
  repos/trade-tariff/example/pulls/232)
    printf '%s\n' '{"number":232,"title":"Bump faraday from 2.14.2 to 2.14.3","html_url":"https://github.com/trade-tariff/example/pull/232","labels":[]}'
    ;;
esac
STUB
  chmod +x "$stub_bin/gh"

  TRIGGER_SHA="trigger-sha" DEPLOY_SHA="deploy-sha" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "#456 — Real triggering PR"
  assert_not_contains "$output_content" "#232"
}

@test "parses merge commit titles to fetch the pull request by number" {
  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" != "api" ]]; then
  exit 1
fi

case "$2" in
  repos/trade-tariff/example/commits/merge-sha)
    printf '%s\n' 'Merge pull request #232 from trade-tariff/dependabot/faraday'
    ;;
  repos/trade-tariff/example/pulls/232)
    printf '%s\n' '{"number":232,"title":"Bump faraday from 2.14.2 to 2.14.3","html_url":"https://github.com/trade-tariff/example/pull/232","labels":[{"name":"low-risk"}]}'
    ;;
esac
STUB
  chmod +x "$stub_bin/gh"

  SHA="merge-sha" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "#232 — Bump faraday from 2.14.2 to 2.14.3"
  assert_contains "$output_content" "Risk: :large_green_circle: low-risk"
}

@test "parses squash merge commit titles to fetch the pull request by number" {
  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" != "api" ]]; then
  exit 1
fi

case "$2" in
  repos/trade-tariff/example/commits/squash-sha)
    printf '%s\n' 'Add new deployment signal (#789)'
    ;;
  repos/trade-tariff/example/pulls/789)
    printf '%s\n' '{"number":789,"title":"Add new deployment signal","html_url":"https://github.com/trade-tariff/example/pull/789","labels":[]}'
    ;;
esac
STUB
  chmod +x "$stub_bin/gh"

  SHA="squash-sha" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "#789 — Add new deployment signal"
}

@test "falls back to the associated pull request endpoint for non-merge commits" {
  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" != "api" ]]; then
  exit 1
fi

case "$2" in
  repos/trade-tariff/example/commits/head-sha)
    printf '%s\n' 'Feature branch commit'
    ;;
  repos/trade-tariff/example/commits/head-sha/pulls)
    printf '%s\n' '{"number":321,"title":"Associated branch PR","html_url":"https://github.com/trade-tariff/example/pull/321","labels":[]}'
    ;;
esac
STUB
  chmod +x "$stub_bin/gh"

  SHA="head-sha" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "#321 — Associated branch PR"
}

@test "outputs PR title and link when a PR is found" {
  make_gh_stub '{"number":99,"title":"My great change","html_url":"https://github.com/trade-tariff/example/pull/99","labels":[]}'

  run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "#99 — My great change"
  assert_contains "$output_content" "https://github.com/trade-tariff/example/pull/99"
}

@test "omits the risk line when the PR has no risk label" {
  make_gh_stub '{"number":99,"title":"My great change","html_url":"https://github.com/trade-tariff/example/pull/99","labels":[{"name":"bug"}]}'

  run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_not_contains "$output_content" "Risk:"
}

@test "includes a green circle for low-risk PRs" {
  make_gh_stub '{"number":1,"title":"Tiny fix","html_url":"https://github.com/trade-tariff/example/pull/1","labels":[{"name":"low-risk"}]}'

  run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" ":large_green_circle:"
  assert_contains "$output_content" "low-risk"
}

@test "includes a yellow circle for medium-risk PRs" {
  make_gh_stub '{"number":2,"title":"Bigger change","html_url":"https://github.com/trade-tariff/example/pull/2","labels":[{"name":"medium-risk"}]}'

  run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" ":large_yellow_circle:"
  assert_contains "$output_content" "medium-risk"
}

@test "includes a red circle for high-risk PRs" {
  make_gh_stub '{"number":3,"title":"Dangerous change","html_url":"https://github.com/trade-tariff/example/pull/3","labels":[{"name":"high-risk"}]}'

  run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" ":red_circle:"
  assert_contains "$output_content" "high-risk"
}

@test "deploy-ecs pr-info step has continue-on-error set" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "continue-on-error: true" "$workflow"
  [ "$status" -eq 0 ]
}

@test "deploy-ecs pr-info step runs the shared script" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "run: .trade-tariff-tools/scripts/deploy-pr-info.sh" "$workflow"
  [ "$status" -eq 0 ]
}

@test "deploy-ecs checks out the reusable workflow source for the shared pr-info script" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "JOB_CONTEXT: \${{ toJson(job) }}" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "repository: \${{ steps.workflow-source.outputs.repository }}" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "ref: \${{ steps.workflow-source.outputs.sha }}" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "path: .trade-tariff-tools" "$workflow"
  [ "$status" -eq 0 ]
}

@test "deploy-ecs sends caller repository and triggering sha to pr-info" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "REPO: \${{ github.repository }}" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "TRIGGER_SHA: \${{ github.event.workflow_run.head_sha || github.event.pull_request.merge_commit_sha || github.event.pull_request.head.sha || github.sha }}" "$workflow"
  [ "$status" -eq 0 ]
}

@test "deploy-ecs checks out the workflow_run head sha when production follows staging" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "ACTUAL_REF=\"\${{ github.event.workflow_run.head_sha || github.event.pull_request.head.sha || github.sha }}\"" "$workflow"
  [ "$status" -eq 0 ]
}

@test "deploy-ecs slack-notify message falls back when pr-info produces no output" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "steps.pr-info.outputs.message ||" "$workflow"
  [ "$status" -eq 0 ]
}

@test "deploy-ecs preserves multiline notification messages in step output" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "BASE: \${{ steps.pr-info.outputs.message ||" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "ROLLBACK: \${{ steps.result.outputs.rollback_message }}" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "echo 'message<<NOTIFY_EOF'" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "printf '%s\\n' \"\$message\"" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "echo 'NOTIFY_EOF'" "$workflow"
  [ "$status" -eq 0 ]
}
