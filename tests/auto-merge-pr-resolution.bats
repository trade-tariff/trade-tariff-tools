#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
  export GITHUB_OUTPUT="$tmpdir/output"
  export GH_ARGS="$tmpdir/gh-args"
  export HEAD_BRANCH="feature/example"
  export GH_PR_NUMBER=42
  event_name=workflow_run
  conclusion=success
  workflow="$repo_root/.github/workflows/auto-merge-low-risk.yml"

  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$GH_ARGS"
printf '%s\n' "$GH_PR_NUMBER"
STUB
  chmod +x "$stub_bin/gh"
}

teardown() {
  rm -rf "$tmpdir"
}

run_resolver() {
  # Execute the actual inline step, modelling expression substitution before Bash.
  local script
  script="$(awk '
    /      - name: Resolve pull request number/ { step = 1; next }
    step && /      - name:/ { exit }
    step && /        run: \|/ { body = 1; next }
    body { sub(/^          /, ""); print }
  ' "$workflow")"
  [ -n "$script" ]
  script="${script//'${{ github.event_name }}'/$event_name}"
  script="${script//'${{ github.event.pull_request.number }}'/42}"
  script="${script//'${{ github.event.workflow_run.conclusion }}'/$conclusion}"
  script="${script//'${{ github.event.workflow_run.head_branch }}'/$HEAD_BRANCH}"
  script="${script//'${{ github.repository }}'/trade-tariff/example}"
  run bash -c "$script"
}

@test "resolver wires the branch through the step environment" {
  run grep -F 'HEAD_BRANCH: ${{ github.event.workflow_run.head_branch }}' "$workflow"
  [ "$status" -eq 0 ]
}

@test "successful workflow resolves the open PR using the literal branch" {
  run_resolver

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=42' ]
  [ "$(cat "$GH_ARGS")" = "$(printf '%s\n' pr list --repo trade-tariff/example --head "$HEAD_BRANCH" --state open --json number -q '.[0].number')" ]
}

@test "valid branch shell syntax is passed literally without executing" {
  export HEAD_BRANCH='feature/$(printf${IFS}INJECTED)`printf${IFS}BACKTICK`'
  git check-ref-format --branch "$HEAD_BRANCH"

  run_resolver

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=42' ]
  run grep -Fx -- "$HEAD_BRANCH" "$GH_ARGS"
  [ "$status" -eq 0 ]
}

@test "unsuccessful workflow skips PR lookup" {
  conclusion=failure

  run_resolver

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=' ]
  [ ! -e "$GH_ARGS" ]
}

@test "missing PR skips auto-merge" {
  export GH_PR_NUMBER=null

  run_resolver

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=' ]
}

@test "PR and review events use their PR number without a branch lookup" {
  for event_name in pull_request pull_request_review; do
    : > "$GITHUB_OUTPUT"
    run_resolver

    [ "$status" -eq 0 ]
    [ "$(cat "$GITHUB_OUTPUT")" = 'number=42' ]
    [ ! -e "$GH_ARGS" ]
  done
}
