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
[[ "$2" == "batch-get-image" ]] && printf '%s\n' "${AWS_MANIFEST:-}"
[[ -n "${AWS_STDERR:-}" ]] && printf '%s\n' "$AWS_STDERR" >&2
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
    step = steps.find { |s| s["id"] == "check-image" }
    abort "Inputs must not be inserted into Bash source" if step.fetch("run").include?("${{")
    expected = { "ECR_URL" => "${{ inputs.ecr-url }}", "REF" => "${{ inputs.ref }}", "REGION" => "${{ inputs.region }}" }
    abort "Inputs must pass through env" unless step.fetch("env") == expected
    puts step.fetch("run")
  ' "$repo_root/.github/actions/build-and-push/action.yml")"
  [ -n "$check_script" ]

  for aws_exit in 0 254; do
    export GITHUB_OUTPUT="$tmpdir/output-$aws_exit"
    run env AWS_EXIT="$aws_exit" AWS_STDERR="An error occurred (ImageNotFoundException)" \
      ECR_URL="123456789012.dkr.ecr.eu-west-1.amazonaws.com/tariff-admin-production" REF="7852bee" REGION="eu-west-1" \
      bash -c "$check_script"

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

@test "image check fails when ECR returns an error other than image not found" {
  check_script="$(ruby -ryaml -e '
    puts YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").find { |s| s["id"] == "check-image" }.fetch("run")
  ' "$repo_root/.github/actions/build-and-push/action.yml")"
  export GITHUB_OUTPUT="$tmpdir/output"

  run env AWS_EXIT=254 AWS_STDERR="An error occurred (ThrottlingException)" \
    ECR_URL="123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production" REF="7852bee" REGION="eu-west-2" \
    bash -c "$check_script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Could not check"
  assert_contains "$output" "ThrottlingException"
  assert_not_contains "$(cat "$GITHUB_OUTPUT")" "exists="
}

@test "build arguments and image names pass through env, not Bash source" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps")
    %w[check-image extract-build-args build-image].each do |id|
      step = steps.find { |s| s["id"] == id }
      abort "#{id} must not insert values into Bash source" if step.fetch("run").include?("${{")
    end
    abort "build-args must pass through env" unless steps.find { |s| s["id"] == "extract-build-args" }.dig("env", "INPUT_BUILD_ARGS") == "${{ inputs.build-args }}"
  ' "$repo_root/.github/actions/build-and-push/action.yml"

  [ "$status" -eq 0 ]
}

@test "build arguments with shell syntax stay data" {
  extract_script="$(ruby -ryaml -e '
    puts YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").find { |s| s["id"] == "extract-build-args" }.fetch("run")
  ' "$repo_root/.github/actions/build-and-push/action.yml")"
  export GITHUB_OUTPUT="$tmpdir/output"

  run env INPUT_BUILD_ARGS='RUBY_VERSION=3.4.1 X=$(touch '"$tmpdir"'/pwned) *' bash -c "$extract_script"

  [ "$status" -eq 0 ]
  [ ! -f "$tmpdir/pwned" ]
  assert_contains "$(cat "$GITHUB_OUTPUT")" "BUILD_ARGS= --build-arg RUBY_VERSION=3.4.1 --build-arg X=\$(touch"
  assert_contains "$(cat "$GITHUB_OUTPUT")" "--build-arg *"
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

source_image="123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production@sha256:$(printf 'a%.0s' {1..64})"
arm64_image="123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production@sha256:$(printf 'b%.0s' {1..64})"
multi_arch_manifest='{"manifests":[{"platform":{"os":"linux","architecture":"amd64"}},{"platform":{"os":"linux","architecture":"arm64"}}]}'

@test "tags the scanned digest of each platform when PLATFORMS is set" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" SOURCE_IMAGE="$source_image $arm64_image" AWS_MANIFEST="$multi_arch_manifest" "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/docker-args.txt")" = "$(printf '%s\n' buildx imagetools create -t "$image" "$source_image" "$arm64_image")" ]
  assert_contains "$(cat "$tmpdir/aws-args.txt")" "batch-get-image"
  assert_contains "$output" "has a build for every platform"
}

@test "fails when the new tag does not have every platform" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" SOURCE_IMAGE="$source_image $arm64_image" AWS_MANIFEST='{"schemaVersion":2,"layers":[]}' "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Image $image has no build for linux/arm64"
}

@test "fails without Docker calls when a source image is not a digest in the target repository" {
  for bad in \
    "123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production:latest" \
    "123456789012.dkr.ecr.eu-west-2.amazonaws.com/other-repo@sha256:$(printf 'b%.0s' {1..64})" \
    "123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production@sha256:def456" \
    '$(id)'; do
    rm -f "$tmpdir/docker-args.txt"
    run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" SOURCE_IMAGE="$source_image $bad" "$script"

    [ "$status" -eq 1 ]
    assert_contains "$output" "is not a digest in 123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production"
    [ ! -f "$tmpdir/docker-args.txt" ]
  done
}

@test "fails without Docker calls when one digest is given for two platforms" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" SOURCE_IMAGE="$source_image $source_image" "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "are not different digests"
  [ ! -f "$tmpdir/docker-args.txt" ]
}

@test "fails without Docker calls when a platform has no source image" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" SOURCE_IMAGE="$source_image " "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Got 1 source images for 2 platforms"
  [ ! -f "$tmpdir/docker-args.txt" ]
  [ ! -f "$tmpdir/aws-args.txt" ]
}

@test "requires SOURCE_IMAGE with PLATFORMS" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" "$script"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: SOURCE_IMAGE"
  [ ! -f "$tmpdir/docker-args.txt" ]
}

@test "succeeds when another run pushed a multi-arch tag with every platform" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" SOURCE_IMAGE="$source_image $arm64_image" DOCKER_EXIT=1 AWS_EXIT=0 AWS_MANIFEST="$multi_arch_manifest" "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "::notice::Image $image already exists in ECR"
  assert_contains "$output" "has a build for every platform"
}

@test "fails when another run pushed the tag without every platform" {
  run env IMAGE_NAME="$image" PLATFORMS="linux/amd64,linux/arm64" SOURCE_IMAGE="$source_image $arm64_image" DOCKER_EXIT=1 AWS_EXIT=0 AWS_MANIFEST='{"schemaVersion":2,"layers":[]}' "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Image $image has no build for linux/arm64"
}

@test "multi-arch steps call the action scripts with their environment" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps")
    expect = {
      "validate-platforms.sh" => %w[PLATFORMS DIGEST_ONLY],
      "check-platforms.sh" => %w[IMAGE_NAME REGION PLATFORMS],
      "build-multi-arch.sh" => %w[ECR_URL REF PLATFORMS BUILD_ARGS],
      "scan-image.sh" => %w[SOURCE_IMAGE PLATFORMS],
    }
    expect.each do |script, vars|
      step = steps.find { |s| s.fetch("run", "") == %("${{ github.action_path }}/#{script}") }
      abort "#{script} must be called from a step" unless step
      missing = vars - step.fetch("env", {}).keys
      abort "#{script} step is missing env #{missing.join(",")}" unless missing.empty?
    end
    validate = steps.index { |s| s.fetch("run", "").include?("validate-platforms.sh") }
    abort "Platforms must be validated before any other step" unless validate == 0
    build = steps.find { |s| s["id"] == "build-multi-arch" }
    scan = steps.index { |s| s.fetch("run", "").include?("scan-image.sh") }
    push = steps.index { |s| s["name"] == "Push multi-arch image" }
    abort "The scan must run on the built digest" unless steps[scan].dig("env", "SOURCE_IMAGE") == "${{ steps.build-multi-arch.outputs.source_image }}"
    native = "${{ inputs.digest-only == #{39.chr}true#{39.chr} && #{39.chr}linux/arm64#{39.chr} || #{39.chr}linux/amd64#{39.chr} }}"
    abort "The build must build only the native platform" unless build.dig("env", "PLATFORMS") == native
    abort "The scan must scan the built platform" unless steps[scan].dig("env", "PLATFORMS") == native
    abort "The push must tag the scanned digest and the arm64 image" unless steps[push].dig("env", "SOURCE_IMAGE") == "${{ steps.build-multi-arch.outputs.source_image }} ${{ inputs.arm64-image }}"
    abort "A digest-only run must not push a tag" unless steps[push].fetch("if").end_with?("&& inputs.digest-only != #{39.chr}true#{39.chr}")
    output = YAML.load_file(ARGV.fetch(0)).dig("outputs", "source-image", "value")
    abort "The action must output the pushed digest" unless output == "${{ steps.build-multi-arch.outputs.source_image }}"
    abort "Builds must be native, without QEMU" if steps.any? { |s| s.fetch("uses", "").include?("setup-qemu-action") }
    abort "The scan must run before the push" unless steps.index(build) < scan && scan < push
    scripts = steps.map { |s| s.fetch("run", "") }.join("\n")
    abort "Multi-arch steps must not rebuild or load images" if scripts.match?(/buildx build|--load/)
  ' "$repo_root/.github/actions/build-and-push/action.yml"

  [ "$status" -eq 0 ]
}

@test "tag-production keeps the docker push for amd64 and copies the manifest for multi-arch" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps")
    default = steps.find { |s| s["if"] == "inputs.platforms == #{39.chr}linux/amd64#{39.chr}" }
    abort "The amd64 step must keep docker pull, tag and push" unless default && default.fetch("run").match?(/docker pull.*docker tag.*docker push/m)
    copy = steps.find { |s| s.fetch("run", "") == %("${{ github.action_path }}/copy-release-tag.sh") }
    abort "The multi-arch step must call copy-release-tag.sh" unless copy && copy["if"] == "inputs.platforms != #{39.chr}linux/amd64#{39.chr}"
    missing = %w[ECR_URL REF REGION] - copy.fetch("env", {}).keys
    abort "copy-release-tag.sh step is missing env #{missing.join(",")}" unless missing.empty?
  ' "$repo_root/.github/actions/tag-production/action.yml"

  [ "$status" -eq 0 ]
}

@test "deploy workflows pass platforms to build-and-push and tag-production" {
  for workflow in deploy-ecs.yml deploy-ecs-v2.yml; do
    run ruby -ryaml -e '
      jobs = YAML.load_file(ARGV.fetch(0)).fetch("jobs")
      %w[build-and-push tag-production].each do |action|
        steps = jobs.values.flat_map { |j| j.fetch("steps", []) }.select { |s| s.fetch("uses", "").include?("/actions/#{action}@") }
        abort "#{action} must be used" if steps.empty?
        steps.each { |s| abort "#{action} must get platforms" unless s.dig("with", "platforms") == "${{ inputs.platforms }}" }
      end
    ' "$repo_root/.github/workflows/$workflow"

    [ "$status" -eq 0 ]
  done
}

@test "deploy workflows build arm64 natively in configure and pass it to the build" {
  for workflow in deploy-ecs.yml deploy-ecs-v2.yml; do
    run ruby -ryaml -e '
      jobs = YAML.load_file(ARGV.fetch(0)).fetch("jobs")
      configure = jobs.fetch("configure")
      runner = "${{ contains(inputs.platforms, #{39.chr}linux/arm64#{39.chr}) && #{39.chr}ubuntu-24.04-arm#{39.chr} || #{39.chr}ubuntu-latest#{39.chr} }}"
      abort "configure must run on arm64 only for arm64 platforms" unless configure.fetch("runs-on") == runner
      step = configure.fetch("steps").find { |s| s["id"] == "build-arm64" }
      abort "configure must build arm64 with build-and-push" unless step && step.fetch("uses").include?("/actions/build-and-push@")
      abort "The arm64 build must run only for arm64 platforms" unless step.fetch("if").include?("contains(inputs.platforms, #{39.chr}linux/arm64#{39.chr})")
      abort "The arm64 build must be digest-only and validate the caller platforms" unless step.dig("with", "platforms") == "${{ inputs.platforms }}" && step.dig("with", "digest-only") == "true"
      abort "configure must output the arm64 image" unless configure.dig("outputs", "arm64_image") == "${{ steps.build-arm64.outputs.source-image }}"
      build = jobs.fetch("build").fetch("steps").find { |s| s.fetch("uses", "").include?("/actions/build-and-push@") }
      abort "build must get the arm64 image" unless build.dig("with", "arm64-image") == "${{ needs.configure.outputs.arm64_image }}"
      abort "build must run on amd64" unless jobs.fetch("build").fetch("runs-on") == "ubuntu-latest"
      abort "configure must output the commit it checked out" unless configure.dig("outputs", "actual_ref") == "${{ steps.config.outputs.commit_sha }}"
      jobs.reject { |name, _| name == "configure" }.each do |name, job|
        job.fetch("steps", []).select { |s| s.fetch("uses", "").include?("/checkout-application-repository@") }.each do |s|
          abort "#{name} must check out the configure commit" unless s.dig("with", "ref") == "${{ needs.configure.outputs.actual_ref }}"
        end
      end
    ' "$repo_root/.github/workflows/$workflow"

    [ "$status" -eq 0 ]
  done
}

@test "single-platform push clears PLATFORMS from the caller environment" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps")
    push = steps.find { |s| s["name"] == "Push image" }
    abort "Push image must set PLATFORMS to an empty value" unless push.fetch("env", {}).key?("PLATFORMS") && push.dig("env", "PLATFORMS") == ""
  ' "$repo_root/.github/actions/build-and-push/action.yml"

  [ "$status" -eq 0 ]
}

@test "third-party actions in build-and-push are pinned to a commit" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps")
    %w[docker/setup-buildx-action aquasecurity/setup-trivy].each do |name|
      step = steps.find { |s| s.fetch("uses", "").start_with?("#{name}@") }
      abort "#{name} must be pinned to a commit SHA" unless step && step.fetch("uses").match?(/@[0-9a-f]{40}$/)
    end
  ' "$repo_root/.github/actions/build-and-push/action.yml"

  [ "$status" -eq 0 ]
}
