#!/usr/bin/env bats

load test_helper

setup() {
  workflows="$repo_root/.github/workflows"
  action='trade-tariff/trade-tariff-tools/.github/actions/checkout-application-repository@main'
}

@test "both e2e workflows check out the e2e-tests repo with the app token action" {
  local workflow
  for workflow in e2e-tests e2e-tests-v2; do
    run grep -F "$action" "$workflows/$workflow.yml"
    [ "$status" -eq 0 ]

    # The plain checkout of the e2e-tests repo must be gone.
    run grep -E 'checkout@v[0-9.]+' "$workflows/$workflow.yml"
    [ "$status" -ne 0 ]
  done
}

@test "both e2e workflows declare the two checkout secrets as optional" {
  local workflow secret
  for workflow in e2e-tests e2e-tests-v2; do
    for secret in checkout-app-id checkout-app-private-key; do
      run grep -F -A 3 "      ${secret}:" "$workflows/$workflow.yml"
      [ "$status" -eq 0 ]
      assert_contains "$output" 'required: false'
    done
  done
}

@test "both e2e workflows pass the secrets to the action" {
  local workflow
  for workflow in e2e-tests e2e-tests-v2; do
    run grep -F 'secrets.checkout-app-id' "$workflows/$workflow.yml"
    [ "$status" -eq 0 ]
    run grep -F 'secrets.checkout-app-private-key' "$workflows/$workflow.yml"
    [ "$status" -eq 0 ]
  done
}

@test "every deploy workflow forwards the secrets to its e2e job" {
  local workflow
  for workflow in deploy-ecs deploy-ecs-v2 deploy-multi-ecs deploy-multi-ecs-v2; do
    # The e2e job block runs from its uses: line to the next blank line.
    run awk '/e2e-tests(-v2)?\.yml@main/{found=1} found{print} found && /^$/{exit}' "$workflows/$workflow.yml"
    [ "$status" -eq 0 ]
    assert_contains "$output" 'checkout-app-id: '
    assert_contains "$output" 'checkout-app-private-key: '
    assert_contains "$output" 'secrets.checkout-app-id'
    assert_contains "$output" 'secrets.checkout-app-private-key'
  done
}
