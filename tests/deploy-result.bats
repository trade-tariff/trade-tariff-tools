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
    FPO_TEST_RESULT="${FPO_TEST_RESULT:-skipped}" \
    TARIFF_TEST_RESULT="${TARIFF_TEST_RESULT:-skipped}" \
    TEST_FLAVOUR="${TEST_FLAVOUR-fpo}" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" \
    "$repo_root/scripts/deploy-result.sh"
}

@test "build failure takes precedence over skipped deployment and tests" {
  BUILD_RESULT="failure" DEPLOY_RESULT="skipped" FPO_TEST_RESULT="skipped" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "result=failure"
  assert_contains "$output_content" "summary=Deploy to staging failed during build"
}

@test "build failure takes precedence when deployment and both tests fail" {
  BUILD_RESULT="failure" DEPLOY_RESULT="failure" FPO_TEST_RESULT="failure" TARIFF_TEST_RESULT="failure" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  [ "$output_content" = "$(printf 'result=failure\nsummary=Deploy to staging failed during build')" ]
}

@test "successful tariff selection ignores an unselected FPO failure" {
  TEST_FLAVOUR="tariff" TARIFF_TEST_RESULT="success" FPO_TEST_RESULT="failure" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  [ "$output_content" = "$(printf 'result=success\nsummary=Deploy to staging success')" ]
}

@test "failing FPO selection ignores an unselected tariff success" {
  TEST_FLAVOUR="fpo" FPO_TEST_RESULT="failure" TARIFF_TEST_RESULT="success" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  [ "$output_content" = "$(printf 'result=failure\nsummary=Deploy to staging failure')" ]
}

@test "unrecognised test flavour uses the deployment result" {
  TEST_FLAVOUR="unknown" DEPLOY_RESULT="success" FPO_TEST_RESULT="failure" TARIFF_TEST_RESULT="failure" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  [ "$output_content" = "$(printf 'result=success\nsummary=Deploy to staging success')" ]
}

@test "empty test flavour uses the deployment result" {
  TEST_FLAVOUR="" DEPLOY_RESULT="success" FPO_TEST_RESULT="failure" TARIFF_TEST_RESULT="failure" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  [ "$output_content" = "$(printf 'result=success\nsummary=Deploy to staging success')" ]
}

@test "deployment failure takes precedence over a skipped test" {
  DEPLOY_RESULT="failure" FPO_TEST_RESULT="skipped" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "result=failure"
  assert_contains "$output_content" "summary=Deploy to staging failed during deployment"
}

@test "successful selected test preserves the existing success result" {
  FPO_TEST_RESULT="success" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "result=success"
  assert_contains "$output_content" "summary=Deploy to staging success"
}

@test "selected end-to-end test failure preserves the existing failure result" {
  TEST_FLAVOUR="tariff" TARIFF_TEST_RESULT="failure" run_script

  [ "$status" -eq 0 ]
  output_content="$(cat "$GITHUB_OUTPUT")"
  assert_contains "$output_content" "result=failure"
  assert_contains "$output_content" "summary=Deploy to staging failure"
}
