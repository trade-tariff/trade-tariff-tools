#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  script="$repo_root/.github/actions/build-and-push/build-multi-arch.sh"
  workdir="$tmpdir/work"
  mkdir -p "$workdir"

  cat > "$stub_bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_CAPTURE_DIR/docker-args.txt"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--metadata-file" && -n "${BUILD_DIGEST:-}" ]]; then
    printf '{"containerimage.digest":"%s"}\n' "$BUILD_DIGEST" >| "$arg"
  fi
  prev="$arg"
done
exit "${DOCKER_EXIT:-0}"
STUB

  chmod +x "$stub_bin/docker"
}

teardown() {
  rm -rf "$tmpdir"
}

ecr_url="123456789012.dkr.ecr.eu-west-2.amazonaws.com/tariff-admin-production"

@test "builds all platforms, pushes by digest and writes the outputs" {
  cd "$workdir"
  run env ECR_URL="$ecr_url" REF="7852bee" PLATFORMS="linux/amd64,linux/arm64" BUILD_ARGS="--build-arg RUBY_VERSION=3.4.7" BUILD_DIGEST="sha256:abc123" RUNNER_TEMP="$tmpdir" GITHUB_OUTPUT="$tmpdir/output" "$script"

  [ "$status" -eq 0 ]
  [ "$(cat REVISION)" = "7852bee" ]
  docker_args="$(cat "$tmpdir/docker-args.txt")"
  assert_contains "$docker_args" "$(printf 'buildx\nbuild\n--provenance=false\n--platform\nlinux/amd64,linux/arm64')"
  assert_contains "$docker_args" "type=image,name=$ecr_url,push-by-digest=true,name-canonical=true,push=true"
  assert_contains "$docker_args" "$(printf -- '--build-arg\nRUBY_VERSION=3.4.7\n.')"
  assert_not_contains "$docker_args" "--load"
  assert_not_contains "$docker_args" "$(printf -- '-t\n')"
  assert_contains "$(cat "$tmpdir/output")" "image_name=$ecr_url:7852bee"
  assert_contains "$(cat "$tmpdir/output")" "source_image=$ecr_url@sha256:abc123"
}

@test "fails when the build reports no digest" {
  cd "$workdir"
  run env ECR_URL="$ecr_url" REF="7852bee" PLATFORMS="linux/amd64,linux/arm64" RUNNER_TEMP="$tmpdir" GITHUB_OUTPUT="$tmpdir/output" "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::The build did not report an image digest."
  [ ! -s "$tmpdir/output" ]
}

@test "fails when the build fails" {
  cd "$workdir"
  run env ECR_URL="$ecr_url" REF="7852bee" PLATFORMS="linux/amd64,linux/arm64" DOCKER_EXIT=1 RUNNER_TEMP="$tmpdir" GITHUB_OUTPUT="$tmpdir/output" "$script"

  [ "$status" -eq 1 ]
  [ ! -s "$tmpdir/output" ]
}

@test "requires ECR_URL, REF and PLATFORMS" {
  for name in ECR_URL REF PLATFORMS; do
    vars=(ECR_URL="$ecr_url" REF="7852bee" PLATFORMS="linux/amd64,linux/arm64")
    run env "${vars[@]}" "$name=" "$script"

    [ "$status" -eq 2 ]
    assert_contains "$output" "Missing required environment variable: $name"
  done
  [ ! -f "$tmpdir/docker-args.txt" ]
}

@test "prints help without Docker calls" {
  run "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: build-multi-arch.sh"
  [ ! -f "$tmpdir/docker-args.txt" ]
}
