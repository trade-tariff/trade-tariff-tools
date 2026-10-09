#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  script="$repo_root/.github/actions/build-and-push/push-image.sh"

  cat > "$stub_bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_CAPTURE_DIR/docker-args.txt"
exit "${DOCKER_EXIT:-0}"
STUB

  cat > "$stub_bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_CAPTURE_DIR/aws-args.txt"
exit "${AWS_EXIT:-0}"
STUB

  chmod +x "$stub_bin/docker" "$stub_bin/aws"
}

teardown() {
  rm -rf "$tmpdir"
}

image="123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production:7852bee"

@test "pushes the image" {
  run env IMAGE_NAME="$image" "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/docker-args.txt")" = "$(printf 'push\n%s' "$image")" ]
  [ ! -f "$tmpdir/aws-args.txt" ]
}

@test "succeeds when the push fails and the tag already exists" {
  run env IMAGE_NAME="$image" DOCKER_EXIT=1 AWS_EXIT=0 "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "::notice::Image $image already exists in ECR"
  aws_args="$(cat "$tmpdir/aws-args.txt")"
  assert_contains "$aws_args" "$(printf -- '--repository-name\ntariff-admin-production')"
  assert_contains "$aws_args" "imageTag=7852bee"
  assert_contains "$aws_args" "$(printf -- '--registry-id\n123456789012')"
  assert_contains "$aws_args" "$(printf -- '--region\neu-west-2')"
}

@test "fails when the push fails and the tag does not exist" {
  run env IMAGE_NAME="$image" DOCKER_EXIT=1 AWS_EXIT=254 "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Failed to push $image"
}

@test "requires IMAGE_NAME" {
  run env -u IMAGE_NAME "$script"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: IMAGE_NAME"
}

@test "build-and-push action delegates the push to the script" {
  action="$repo_root/.github/actions/build-and-push/action.yml"

  run grep -F "run: '\"\${{ github.action_path }}/push-image.sh\"'" "$action"
  [ "$status" -eq 0 ]
  run grep -F 'IMAGE_NAME: ${{ steps.build-image.outputs.image_name }}' "$action"
  [ "$status" -eq 0 ]
  run grep -F 'REGION: ${{ inputs.region }}' "$action"
  [ "$status" -eq 0 ]
}
