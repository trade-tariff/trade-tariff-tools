#!/usr/bin/env bats

load test_helper

@test "importmap-update action checks out the caller repository with the update token" {
  action="$repo_root/.github/actions/importmap-update/action.yml"

  run grep -F "uses: actions/checkout@v7.0.0" "$action"
  [ "$status" -eq 0 ]

  run grep -F 'token: ${{ inputs.github-token }}' "$action"
  [ "$status" -eq 0 ]
}

@test "importmap-update action sets up Ruby before running the updater" {
  action="$repo_root/.github/actions/importmap-update/action.yml"

  run grep -F "uses: ruby/setup-ruby@v1.316.0" "$action"
  [ "$status" -eq 0 ]

  run grep -F 'bundler-cache: ${{ inputs.bundler-cache }}' "$action"
  [ "$status" -eq 0 ]
}

@test "importmap-update action delegates to thoughtbot importmap-update" {
  action="$repo_root/.github/actions/importmap-update/action.yml"

  run grep -F "uses: thoughtbot/importmap-update@v1.0.0-alpha3" "$action"
  [ "$status" -eq 0 ]

  run grep -F 'github-token: ${{ inputs.github-token }}' "$action"
  [ "$status" -eq 0 ]

  run grep -F 'dry-run: ${{ inputs.dry-run }}' "$action"
  [ "$status" -eq 0 ]
}

@test "ci runs when the importmap-update action changes" {
  workflow="$repo_root/.github/workflows/ci.yml"

  run grep -F ".github/actions/importmap-update/**" "$workflow"
  [ "$status" -eq 0 ]
}
