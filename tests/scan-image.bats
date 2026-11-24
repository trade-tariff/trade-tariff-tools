#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  script="$repo_root/.github/actions/build-and-push/scan-image.sh"

  cat > "$stub_bin/trivy" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/trivy-calls.txt"
[[ "$*" == *"--platform ${TRIVY_FAIL_PLATFORM:-none} "* ]] && exit 1
exit 0
STUB

  chmod +x "$stub_bin/trivy"
}

teardown() {
  rm -rf "$tmpdir"
}

source_image="123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production@sha256:abc123"

@test "scans the registry digest one time for each platform" {
  run env SOURCE_IMAGE="$source_image" PLATFORMS="linux/amd64,linux/arm64" "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/trivy-calls.txt")" = "$(printf '%s\n' \
    "image --image-src remote --platform linux/amd64 --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 $source_image" \
    "image --image-src remote --platform linux/arm64 --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 $source_image")" ]
}

@test "fails when the first platform has findings and does not scan the rest" {
  run env SOURCE_IMAGE="$source_image" PLATFORMS="linux/amd64,linux/arm64" TRIVY_FAIL_PLATFORM="linux/amd64" "$script"

  [ "$status" -eq 1 ]
  [ "$(wc -l < "$tmpdir/trivy-calls.txt" | tr -d ' ')" = "1" ]
}

@test "fails when a later platform has findings" {
  run env SOURCE_IMAGE="$source_image" PLATFORMS="linux/amd64,linux/arm64" TRIVY_FAIL_PLATFORM="linux/arm64" "$script"

  [ "$status" -eq 1 ]
  [ "$(wc -l < "$tmpdir/trivy-calls.txt" | tr -d ' ')" = "2" ]
}

@test "requires SOURCE_IMAGE and PLATFORMS" {
  for name in SOURCE_IMAGE PLATFORMS; do
    run env SOURCE_IMAGE="$source_image" PLATFORMS="linux/amd64,linux/arm64" "$name=" "$script"

    [ "$status" -eq 2 ]
    assert_contains "$output" "Missing required environment variable: $name"
  done
  [ ! -f "$tmpdir/trivy-calls.txt" ]
}

@test "prints help without Trivy calls" {
  run "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: scan-image.sh"
  [ ! -f "$tmpdir/trivy-calls.txt" ]
}
