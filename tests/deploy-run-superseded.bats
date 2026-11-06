#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
  export GITHUB_OUTPUT="$tmpdir/github_output"
  touch "$GITHUB_OUTPUT"
}

teardown() {
  rm -rf "$tmpdir"
}

make_gh_stub() {
  cat > "$stub_bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$tmpdir/gh_args"
$1
STUB
  chmod +x "$stub_bin/gh"
}

run_script() {
  run env \
    REPO="trade-tariff/example" \
    RESULT="$1" \
    RUN_NUMBER="10" \
    WORKFLOW_REF="trade-tariff/example/.github/workflows/deploy-to-development.yml@refs/pull/1/merge" \
    GITHUB_OUTPUT="$GITHUB_OUTPUT" \
    "$repo_root/scripts/deploy-run-superseded.sh"
}

@test "a cancelled run is superseded when a newer run exists" {
  make_gh_stub "echo 11"

  run_script cancelled

  [ "$status" -eq 0 ]
  grep -qx "superseded=true" "$GITHUB_OUTPUT"
  assert_contains "$(cat "$tmpdir/gh_args")" "actions/workflows/deploy-to-development.yml/runs"
}

@test "a skipped run is superseded when a newer run exists" {
  make_gh_stub "echo 11"

  run_script skipped

  [ "$status" -eq 0 ]
  grep -qx "superseded=true" "$GITHUB_OUTPUT"
}

@test "a cancelled run is not superseded when it is the newest run" {
  make_gh_stub "echo 10"

  run_script cancelled

  [ "$status" -eq 0 ]
  grep -qx "superseded=false" "$GITHUB_OUTPUT"
}

@test "a finished run is never superseded" {
  make_gh_stub "echo 11"

  for result in success failure; do
    run_script "$result"

    [ "$status" -eq 0 ]
  done

  ! grep -q "superseded=true" "$GITHUB_OUTPUT"
}

@test "keeps the notification when the lookup fails" {
  make_gh_stub "exit 1"

  run_script cancelled

  [ "$status" -eq 0 ]
  grep -qx "superseded=false" "$GITHUB_OUTPUT"
}

@test "keeps the notification when the lookup returns no number" {
  make_gh_stub "echo not-a-number"

  run_script cancelled

  [ "$status" -eq 0 ]
  grep -qx "superseded=false" "$GITHUB_OUTPUT"
}
