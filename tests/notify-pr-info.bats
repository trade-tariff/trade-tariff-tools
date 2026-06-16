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

extract_pr_info_script() {
  ruby -ryaml -e '
    workflow = YAML.load_file(ARGV.fetch(0))
    steps = workflow.fetch("jobs").fetch("notify").fetch("steps")
    step = steps.find { |s| s["id"] == "pr-info" }
    puts step.fetch("run")
  ' "$repo_root/.github/workflows/deploy-ecs.yml"
}

run_script() {
  script="$tmpdir/pr-info.sh"
  extract_pr_info_script > "$script"

  run env \
    SHA="abc1234" \
    REPO="trade-tariff/example" \
    ENVIRONMENT="production" \
    RESULT="success" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" \
    bash "$script"
}

@test "outputs a plain fallback message when the API returns no PR" {
  make_gh_stub ""

  run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "message=Deploy to production success"
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

@test "deploy-ecs slack-notify message falls back when pr-info produces no output" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "steps.pr-info.outputs.message ||" "$workflow"
  [ "$status" -eq 0 ]
}
