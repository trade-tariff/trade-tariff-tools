#!/usr/bin/env bats

load test_helper

setup() {
  script="$repo_root/.github/actions/build-and-push/validate-platforms.sh"
}

@test "accepts the default linux/amd64" {
  run env PLATFORMS="linux/amd64" "$script"

  [ "$status" -eq 0 ]
}

@test "accepts linux/amd64 with linux/arm64" {
  run env PLATFORMS="linux/amd64,linux/arm64" "$script"

  [ "$status" -eq 0 ]
}

@test "rejects linux/arm64 without linux/amd64" {
  run env PLATFORMS="linux/arm64" "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Platforms linux/arm64 must include linux/amd64."
}

@test "rejects a platform with a variant" {
  run env PLATFORMS="linux/amd64,linux/arm64/v8" "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Platform linux/arm64/v8 is not supported."
}

@test "rejects an unknown platform" {
  run env PLATFORMS="linux/amd64,linux/s390x" "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Platform linux/s390x is not supported."
}

@test "requires PLATFORMS" {
  run env -u PLATFORMS "$script"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: PLATFORMS"
}

@test "prints help" {
  run env -u PLATFORMS "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: validate-platforms.sh"
}
