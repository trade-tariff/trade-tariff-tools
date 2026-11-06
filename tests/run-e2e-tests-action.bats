#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
  export TEST_CAPTURE_DIR="$tmpdir"
  export PROJECTS="api,frontend" TEST_ENVIRONMENT="staging"
  export SKIP_PASSWORDLESS_VERIFICATION=true MAKE_STATUS=0
  script="$repo_root/.github/actions/run-e2e-tests/run-e2e-tests.sh"

  cat > "$stub_bin/make" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_CAPTURE_DIR/make-args"
printf '%s\n' "$SKIP_PASSWORDLESS_VERIFICATION" > "$TEST_CAPTURE_DIR/passwordless"
pwd -P > "$TEST_CAPTURE_DIR/working-directory"
exit "$MAKE_STATUS"
STUB
  chmod +x "$stub_bin/make"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "launcher passes selected projects and environment to Make in the suite directory" {
  cd "$tmpdir"
  expected_working_directory="$(pwd -P)"
  run "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/make-args")" = "$(printf 'test\nenvironment=staging\nprojects=api,frontend')" ]
  [ "$(cat "$tmpdir/passwordless")" = true ]
  [ "$(cat "$tmpdir/working-directory")" = "$expected_working_directory" ]
}

@test "all projects run when passwordless verification is enabled for them" {
  for project in api frontend admin dev-hub myott; do
    PROJECTS="$project" SKIP_PASSWORDLESS_VERIFICATION=false run "$script"

    [ "$status" -eq 0 ]
    [ "$(cat "$tmpdir/passwordless")" = false ]
    assert_contains "$(cat "$tmpdir/make-args")" "projects=$project"
  done
}

@test "passwordless projects are filtered out with a warning when verification is skipped" {
  PROJECTS="api, admin ,frontend,myott" run "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "Skipping admin"
  assert_contains "$output" "Skipping myott"
  [ "$(cat "$tmpdir/make-args")" = "$(printf 'test\nenvironment=staging\nprojects=api,frontend')" ]
}

@test "passwordless projects are filtered out in production" {
  TEST_ENVIRONMENT=production SKIP_PASSWORDLESS_VERIFICATION=false PROJECTS="dev-hub,api" run "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/make-args")" = "$(printf 'test\nenvironment=production\nprojects=api')" ]
}

@test "launcher skips Make when no selected project is enabled" {
  PROJECTS="admin,dev-hub" run "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "Skipping E2E tests"
  [ ! -f "$tmpdir/make-args" ]
}

@test "mixed and reordered selections keep their order when verification is enabled" {
  SKIP_PASSWORDLESS_VERIFICATION=false PROJECTS=' myott , api , admin ' run "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/make-args")" = "$(printf 'test\nenvironment=staging\nprojects=myott,api,admin')" ]
}

@test "launcher preserves an explicit false flag" {
  SKIP_PASSWORDLESS_VERIFICATION=false run "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/passwordless")" = false ]
}

@test "launcher defaults to skipping passwordless when the flag is unset" {
  PROJECTS=api run env -u SKIP_PASSWORDLESS_VERIFICATION "$script"

  [ "$status" -eq 0 ]
  [ "$(cat "$tmpdir/passwordless")" = true ]
}

@test "empty and malformed project selections fail before Make runs" {
  for projects in '' '   ' ',' ',api' 'api,' 'api,,frontend' 'api, ,frontend'; do
    PROJECTS="$projects" run "$script"

    [ "$status" -eq 2 ]
    [ -n "$output" ]
    [ ! -f "$tmpdir/make-args" ]
  done
}

@test "unsupported names and project substrings fail before Make runs" {
  for projects in 'administrator' 'api,myott-extra' 'api;echo unexpected' '$(shell echo unexpected)'; do
    PROJECTS="$projects" run "$script"

    [ "$status" -eq 2 ]
    assert_contains "$output" "Unsupported E2E project:"
    [ ! -f "$tmpdir/make-args" ]
  done
}

@test "missing required inputs and invalid booleans report usage errors" {
  for variable in PROJECTS TEST_ENVIRONMENT; do
    run env -u "$variable" "$script"

    [ "$status" -eq 2 ]
    assert_contains "$output" "Missing required environment variable: $variable"
  done

  SKIP_PASSWORDLESS_VERIFICATION=invalid run "$script"
  [ "$status" -eq 2 ]
  assert_contains "$output" "SKIP_PASSWORDLESS_VERIFICATION must be true or false"
  [ ! -f "$tmpdir/make-args" ]
}

@test "launcher accepts only supported test environments" {
  for environment in development staging production; do
    TEST_ENVIRONMENT="$environment" run "$script"

    [ "$status" -eq 0 ]
    assert_contains "$(cat "$tmpdir/make-args")" "environment=$environment"
  done

  for environment in invalid 'staging; touch unexpected' '$(shell echo unexpected)'; do
    rm -f "$tmpdir/make-args"
    TEST_ENVIRONMENT="$environment" run "$script"

    [ "$status" -eq 2 ]
    assert_contains "$output" "Unsupported test environment:"
    [ ! -f "$tmpdir/make-args" ]
  done
}

@test "launcher propagates Make failures" {
  MAKE_STATUS=2 run "$script"

  [ "$status" -eq 2 ]
  [ -f "$tmpdir/make-args" ]
}

@test "launcher help needs no environment and does not run Make" {
  run env -u PROJECTS -u TEST_ENVIRONMENT "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: run-e2e-tests.sh"
  [ ! -f "$tmpdir/make-args" ]
}

@test "composite action passes its inputs through environment to its launcher" {
  run ruby -ryaml -e '
    action = YAML.load_file(ARGV.fetch(0))
    inputs = action.fetch("inputs")
    abort "Default projects changed" unless inputs.dig("projects", "default") == "api,frontend"
    abort "Default passwordless behaviour changed" unless inputs.dig("skip-passwordless", "default") == "true"
    inputs.each_value do |input|
      abort "Inputs need descriptions and required declarations" unless input.key?("required") && input["description"].to_s.length.positive?
    end
    step = action.fetch("runs").fetch("steps").fetch(0)
    abort "Launcher must run in Bash" unless step.fetch("shell") == "bash"
    abort "Launcher must use the action path" unless step.fetch("run") == %q{"${{ github.action_path }}/run-e2e-tests.sh"}
    expected = {
      "PROJECTS" => "${{ inputs.projects }}",
      "TEST_ENVIRONMENT" => "${{ inputs.test-environment }}",
      "SKIP_PASSWORDLESS_VERIFICATION" => "${{ inputs.skip-passwordless }}"
    }
    abort "Launcher input wiring changed" unless step.fetch("env") == expected
  ' "$repo_root/.github/actions/run-e2e-tests/action.yml"

  [ "$status" -eq 0 ]
}
