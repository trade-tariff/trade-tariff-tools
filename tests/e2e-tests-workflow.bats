#!/usr/bin/env bats

load test_helper

@test "e2e workflow installs only Chromium headless shell" {
  workflow="$repo_root/.github/workflows/e2e-tests.yml"

  run grep -F \
    "yarn playwright install --with-deps --only-shell chromium" \
    "$workflow"

  [ "$status" -eq 0 ]
}
