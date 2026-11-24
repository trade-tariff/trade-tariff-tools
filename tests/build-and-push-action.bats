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

@test "prints help without Docker or AWS calls" {
  run env -u IMAGE_NAME "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: push-image.sh"
  [ ! -f "$tmpdir/docker-args.txt" ]
  [ ! -f "$tmpdir/aws-args.txt" ]
}

@test "rejects unknown arguments without Docker or AWS calls" {
  run env IMAGE_NAME="$image" "$script" --unknown

  [ "$status" -eq 2 ]
  assert_contains "$output" "Unknown argument: --unknown"
  assert_contains "$output" "Usage: push-image.sh"
  [ ! -f "$tmpdir/docker-args.txt" ]
  [ ! -f "$tmpdir/aws-args.txt" ]
}

@test "passes an explicit region to the ECR fallback" {
  run env IMAGE_NAME="$image" REGION="eu-west-1" DOCKER_EXIT=1 AWS_EXIT=0 "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "::notice::Image $image already exists in ECR"
  [ "$(cat "$tmpdir/docker-args.txt")" = "$(printf 'push\n%s' "$image")" ]
  aws_args="$(cat "$tmpdir/aws-args.txt")"
  assert_contains "$aws_args" "$(printf 'ecr\ndescribe-images')"
  assert_contains "$aws_args" "$(printf -- '--region\neu-west-1')"
  assert_not_contains "$aws_args" "$(printf -- '--region\neu-west-2')"
}

@test "build-and-push logs in to the target ECR registry without APT or a credential helper" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps")
    login = steps.find { |step| step.fetch("uses", "").start_with?("aws-actions/amazon-ecr-login@") }
    abort "ECR login must exist" unless login
    abort "ECR login must use an immutable commit" unless login.fetch("uses").match?(/@[0-9a-f]{40}$/)
    abort "Existing images must skip login" unless login.fetch("if") == "steps.check-image.outputs.exists == #{39.chr}false#{39.chr}"
    abort "Login must target the image registry account" unless login.dig("with", "registries") == "${{ steps.check-image.outputs.registry-id }}"
    credentials = steps.index { |step| step.fetch("uses", "").start_with?("aws-actions/configure-aws-credentials@") }
    check = steps.index { |step| step["id"] == "check-image" }
    build = steps.index { |step| step["id"] == "build-image" }
    abort "Login must follow credentials and the image check, before building" unless credentials < check && check < steps.index(login) && steps.index(login) < build
    scripts = steps.map { |step| step.fetch("run", "") }.join("\n")
    abort "ECR login must not depend on APT or overwrite Docker configuration" if scripts.match?(/apt-get|credHelpers|config\.json/)
  ' "$repo_root/.github/actions/build-and-push/action.yml"

  [ "$status" -eq 0 ]
}

@test "image check exposes the target registry for new and existing cross-account images" {
  check_script="$(ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps")
    script = steps.find { |step| step["id"] == "check-image" }.fetch("run")
    { "ecr-url" => "123456789012.dkr.ecr.eu-west-1.amazonaws.com/tariff-admin-production", "ref" => "7852bee", "region" => "eu-west-1" }.each do |key, value|
      script = script.gsub("${{ inputs.#{key} }}", value)
    end
    puts script
  ' "$repo_root/.github/actions/build-and-push/action.yml")"

  for aws_exit in 0 254; do
    export GITHUB_OUTPUT="$tmpdir/output-$aws_exit"
    run env AWS_EXIT="$aws_exit" bash -c "$check_script"

    [ "$status" -eq 0 ]
    assert_contains "$(cat "$GITHUB_OUTPUT")" "registry-id=123456789012"
    if [ "$aws_exit" -eq 0 ]; then
      assert_contains "$(cat "$GITHUB_OUTPUT")" "exists=true"
    else
      assert_contains "$(cat "$GITHUB_OUTPUT")" "exists=false"
    fi
    assert_contains "$(cat "$tmpdir/aws-args.txt")" "$(printf -- '--region\neu-west-1')"
    assert_contains "$(cat "$tmpdir/aws-args.txt")" "$(printf -- '--registry-id\n123456789012')"
  done
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

@test "builds and pushes a multi-arch image when PLATFORMS is set" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" BUILD_ARGS="--build-arg RUBY_VERSION=3.4.7 --build-arg ALPINE_VERSION=3.24" "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/docker-args.txt")" = "$(printf '%s\n' buildx build --provenance=false --platform linux/amd64,linux/arm64 --push -t "$image" --build-arg RUBY_VERSION=3.4.7 --build-arg ALPINE_VERSION=3.24 .)" ]
  [ ! -f "$tmpdir/aws-args.txt" ]
}

@test "builds a multi-arch image without BUILD_ARGS" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/docker-args.txt")" = "$(printf '%s\n' buildx build --provenance=false --platform linux/amd64,linux/arm64 --push -t "$image" .)" ]
}

@test "succeeds when the multi-arch push fails and the tag already exists" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" DOCKER_EXIT=1 AWS_EXIT=0 "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "::notice::Image $image already exists in ECR"
}
