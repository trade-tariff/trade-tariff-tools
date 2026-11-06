#!/usr/bin/env bats

load test_helper

@test "legacy deployment workflows keep the flavour interface and the FPO workflow" {
  [ -e "$repo_root/.github/workflows/e2e-fpo-tests.yml" ]
  run grep -c 'test-flavour' \
    "$repo_root/.github/workflows/deploy-ecs.yml" \
    "$repo_root/.github/workflows/deploy-multi-ecs.yml"

  [ "$status" -eq 0 ]
  run grep -E 'test-projects' \
    "$repo_root/.github/workflows/deploy-ecs.yml" \
    "$repo_root/.github/workflows/deploy-multi-ecs.yml"

  [ "$status" -eq 1 ]
}
