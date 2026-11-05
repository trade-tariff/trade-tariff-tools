#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export GITHUB_OUTPUT="$tmpdir/github_output"
  touch "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$tmpdir"
}

run_script() {
  run env \
    BUILD_RESULT="${BUILD_RESULT:-success}" \
    DEPLOY_RESULT="${DEPLOY_RESULT:-success}" \
    ENVIRONMENT="staging" \
    E2E_TEST_RESULT="${E2E_TEST_RESULT-skipped}" \
    TEST_PROJECTS="${TEST_PROJECTS-api,frontend}" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" \
    "$repo_root/scripts/deploy-result-v2.sh"
}

@test "build failure takes precedence over skipped deployment and tests" {
  BUILD_RESULT="failure" DEPLOY_RESULT="skipped" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "result=failure"
  assert_contains "$output_content" "summary=Deploy to staging failed during build"
}

@test "build failure takes precedence when deployment and tests fail" {
  BUILD_RESULT="failure" DEPLOY_RESULT="failure" E2E_TEST_RESULT="failure" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  [ "$output_content" = "$(printf 'result=failure\nsummary=Deploy to staging failed during build')" ]
}

@test "successful selected E2E test produces a success result" {
  E2E_TEST_RESULT="success" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  [ "$output_content" = "$(printf 'result=success\nsummary=Deploy to staging success')" ]
}

@test "selected E2E test failure produces a failure result" {
  E2E_TEST_RESULT="failure" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  [ "$output_content" = "$(printf 'result=failure\nsummary=Deploy to staging failure')" ]
}

@test "empty selection uses the deployment result despite an unrelated test result" {
  TEST_PROJECTS="" E2E_TEST_RESULT="failure" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  [ "$output_content" = "$(printf 'result=success\nsummary=Deploy to staging success')" ]
}

@test "empty selection preserves successful deployment when E2E is skipped" {
  TEST_PROJECTS="" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  [ "$output_content" = "$(printf 'result=success\nsummary=Deploy to staging success')" ]
}

@test "deployment failure takes precedence over a skipped test" {
  DEPLOY_RESULT="failure" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "result=failure"
  assert_contains "$output_content" "summary=Deploy to staging failed during deployment"
}

@test "selected skipped and cancelled E2E jobs are not reported as success" {
  for result in skipped cancelled; do
    : > "$GITHUB_OUTPUT"
    E2E_TEST_RESULT="$result" run_script

    [ "$status" -eq 0 ]
    [ "$(cat "$GITHUB_OUTPUT")" = "$(printf 'result=%s\nsummary=Deploy to staging %s' "$result" "$result")" ]
  done
}

@test "cancelled build and deployment results are preserved when tests are skipped" {
  BUILD_RESULT=cancelled DEPLOY_RESULT=skipped run_script
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$GITHUB_OUTPUT")" "result=cancelled"

  : > "$GITHUB_OUTPUT"
  DEPLOY_RESULT=cancelled run_script
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$GITHUB_OUTPUT")" "result=cancelled"
}

@test "missing selected E2E result reports an error instead of success" {
  E2E_TEST_RESULT="" run_script

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: E2E_TEST_RESULT"
  [ ! -s "$GITHUB_OUTPUT" ]
}
