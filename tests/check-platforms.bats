#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  script="$repo_root/.github/actions/build-and-push/check-platforms.sh"

  cat > "$stub_bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_CAPTURE_DIR/aws-args.txt"
printf '%s\n' "${AWS_MANIFEST:-}"
exit "${AWS_EXIT:-0}"
STUB

  chmod +x "$stub_bin/aws"
}

teardown() {
  rm -rf "$tmpdir"
}

image="123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production:7852bee"
multi_arch_manifest='{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64","variant":"v8"}}]}'
single_manifest='{"schemaVersion":2,"config":{},"layers":[]}'

@test "passes when the index has every platform" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" AWS_MANIFEST="$multi_arch_manifest" "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "::notice::Image $image has a build for every platform"
  aws_args="$(cat "$tmpdir/aws-args.txt")"
  assert_contains "$aws_args" "$(printf 'ecr\nbatch-get-image')"
  assert_contains "$aws_args" "$(printf -- '--repository-name\ntariff-admin-production')"
  assert_contains "$aws_args" "imageTag=7852bee"
  assert_contains "$aws_args" "$(printf -- '--registry-id\n123456789012')"
}

@test "matches a platform with or without the variant of the index entry" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/arm64/v8,linux/arm64" AWS_MANIFEST="$multi_arch_manifest" "$script"

  [ "$status" -eq 0 ]
}

@test "does not match a different variant" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/arm/v6" AWS_MANIFEST='{"manifests":[{"platform":{"os":"linux","architecture":"arm","variant":"v7"}}]}' "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "has no build for linux/arm/v6. It has linux/arm/v7."
}

@test "fails when the index has no build for a platform" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64,linux/s390x" AWS_MANIFEST="$multi_arch_manifest" "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Image $image has no build for linux/s390x. It has linux/amd64,linux/arm64/v8."
  assert_contains "$output" "deploy a new commit to build a new tag"
}

@test "counts a single image manifest as linux/amd64" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" AWS_MANIFEST="$single_manifest" "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "has no build for linux/arm64. It has linux/amd64."
}

@test "fails when ECR does not return the manifest" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" AWS_EXIT=254 "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Could not read the manifest of $image"
}

@test "requires PLATFORMS" {
  run env -u PLATFORMS IMAGE_NAME="$image" "$script"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: PLATFORMS"
  [ ! -f "$tmpdir/aws-args.txt" ]
}

@test "prints help without AWS calls" {
  run env -u IMAGE_NAME "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: check-platforms.sh"
  [ ! -f "$tmpdir/aws-args.txt" ]
}
