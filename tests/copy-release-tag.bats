#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  script="$repo_root/.github/actions/tag-production/copy-release-tag.sh"

  cat > "$stub_bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/docker-calls.txt"
[[ "$1" == "login" ]] && cat > /dev/null
[[ "$1" == "buildx" ]] && exit "${COPY_EXIT:-0}"
exit 0
STUB

  cat > "$stub_bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/aws-calls.txt"
[[ "$2" == "describe-images" ]] && exit "${DESCRIBE_EXIT:-0}"
echo "password"
STUB

  cat > "$stub_bin/date" <<'STUB'
#!/usr/bin/env bash
echo "20261125-0900"
STUB

  chmod +x "$stub_bin/docker" "$stub_bin/aws" "$stub_bin/date"
}

teardown() {
  rm -rf "$tmpdir"
}

ecr_url="123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production"

@test "copies the whole manifest to a release tag without a pull" {
  run env ECR_URL="$ecr_url" REF="7852bee" "$script"

  [ "$status" -eq 0 ]
  docker_calls="$(cat "$tmpdir/docker-calls.txt")"
  assert_contains "$docker_calls" "login --username AWS --password-stdin $ecr_url"
  assert_contains "$docker_calls" "buildx imagetools create --prefer-index=false -t $ecr_url:release-20261125-0900 $ecr_url:7852bee"
  assert_not_contains "$docker_calls" "pull"
  assert_contains "$(cat "$tmpdir/aws-calls.txt")" "ecr describe-images --repository-name tariff-admin-production --image-ids imageTag=7852bee --region eu-west-2 --registry-id 123456789012"
  assert_contains "$output" "::notice::Successfully pushed $ecr_url:release-20261125-0900"
}

@test "fails when the image is not in ECR" {
  run env ECR_URL="$ecr_url" REF="7852bee" DESCRIBE_EXIT=254 "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Image $ecr_url:7852bee not found in ECR"
  assert_not_contains "$(cat "$tmpdir/docker-calls.txt")" "imagetools"
}

@test "fails when the copy fails" {
  run env ECR_URL="$ecr_url" REF="7852bee" COPY_EXIT=1 "$script"

  [ "$status" -eq 1 ]
  assert_contains "$(cat "$tmpdir/docker-calls.txt")" "buildx imagetools create"
  assert_not_contains "$output" "Successfully pushed"
}

@test "uses an explicit region" {
  run env ECR_URL="$ecr_url" REF="7852bee" REGION="eu-west-1" "$script"

  [ "$status" -eq 0 ]
  assert_contains "$(cat "$tmpdir/aws-calls.txt")" "--region eu-west-1"
  assert_not_contains "$(cat "$tmpdir/aws-calls.txt")" "--region eu-west-2"
}

@test "requires ECR_URL and REF" {
  for name in ECR_URL REF; do
    run env ECR_URL="$ecr_url" REF="7852bee" "$name=" "$script"

    [ "$status" -eq 2 ]
    assert_contains "$output" "Missing required environment variable: $name"
  done
  [ ! -f "$tmpdir/aws-calls.txt" ]
}

@test "prints help without AWS or Docker calls" {
  run "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: copy-release-tag.sh"
  [ ! -f "$tmpdir/aws-calls.txt" ]
  [ ! -f "$tmpdir/docker-calls.txt" ]
}
