#!/usr/bin/env bats

load test_helper

@test "risk label reusable workflow delegates to the risk-label action" {
  workflow="$repo_root/.github/workflows/risk-label-reusable.yml"

  run grep -F "uses: trade-tariff/trade-tariff-tools/.github/actions/risk-label@main" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "actions/github-script" "$workflow"
  [ "$status" -ne 0 ]

  run grep -F "pull-requests: write" "$workflow"
  [ "$status" -eq 0 ]
}
