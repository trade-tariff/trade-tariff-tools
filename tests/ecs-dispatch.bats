#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
  export TEST_CAPTURE_DIR="$tmpdir/capture" TEST_REPO_ROOT="$repo_root"
  mkdir -p "$TEST_CAPTURE_DIR"

  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/gh-calls.txt"
case "$1 $2" in
  "repo view")
    echo main
    ;;
  "workflow list")
    if [[ "${TEST_GH_FAILURE:-}" == list ]]; then
      echo "GitHub authentication failed" >&2
      exit 1
    fi
    if [[ "${TEST_NO_WORKFLOWS:-}" == true ]]; then
      echo '[]'
    else
      cat <<'JSON'
[{"id":11,"name":"Start Development Services","path":".github/workflows/start-development-services.yml"},{"id":22,"name":"CI","path":".github/workflows/ci.yml"},{"id":33,"name":"Deploy to ECS","path":".github/workflows/deploy-ecs.yml"},{"id":44,"name":"Rotate ECS Task Definitions","path":".github/workflows/rotate-task-definitions.yml"}]
JSON
    fi
    ;;
  "workflow view")
    if [[ "${TEST_GH_FAILURE:-}" == view || "${TEST_MISSING_WORKFLOW_ID:-}" == "$3" ]]; then
      echo "Cannot read workflow" >&2
      exit 1
    fi
    case "$3" in
      11) cat "$TEST_REPO_ROOT/.github/workflows/start-development-services.yml" ;;
      22) cat "$TEST_REPO_ROOT/.github/workflows/ci.yml" ;;
      33) cat "$TEST_REPO_ROOT/.github/workflows/deploy-ecs.yml" ;;
      44) cat "$TEST_REPO_ROOT/.github/workflows/rotate-task-definitions.yml" ;;
      *) exit 1 ;;
    esac
    ;;
  "workflow run")
    printf '%s\n' "$@" > "$TEST_CAPTURE_DIR/dispatch-args.txt"
    if [[ "${TEST_GH_FAILURE:-}" == run ]]; then
      echo "Workflow dispatch forbidden" >&2
      exit 1
    fi
    if [[ "${TEST_PROMPT_INPUT:-}" == true ]]; then
      printf 'How many revisions? '
      read -r revisions
      printf '%s\n' "$revisions" > "$TEST_CAPTURE_DIR/workflow-input.txt"
    fi
    echo 'Created workflow_dispatch event'
    ;;
  *)
    echo "Unexpected gh command: $*" >&2
    exit 1
    ;;
esac
STUB

  cat > "$stub_bin/fzf" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$TEST_CAPTURE_DIR/fzf-args.txt"
input="$(cat)"
printf '%s\n' "$input" > "$TEST_CAPTURE_DIR/workflow-choices.txt"
if [[ "${TEST_FZF_CANCEL:-}" == true ]]; then
  exit 130
fi
printf '%s\n' "$input" | awk -F '\t' -v id="${TEST_SELECT_ID:-11}" '$1 == id'
STUB

  cat > "$stub_bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "AWS must not be called for dispatch" >&2
touch "$TEST_CAPTURE_DIR/aws-called"
exit 1
STUB
  chmod +x "$stub_bin/gh" "$stub_bin/fzf" "$stub_bin/aws"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "ecs dispatch fuzzy-selects only manual workflows and dispatches by ID" {
  cd "$tmpdir"
  run env GH_REPO=other/repository "$repo_root/bin/ecs" dispatch <<< y

  [ "$status" -eq 0 ]
  assert_contains "$output" "Created workflow_dispatch event"
  assert_contains "$output" "Workflow: Start Development Services"
  assert_contains "$output" "Repository: trade-tariff/trade-tariff-tools"
  assert_contains "$output" "Ref: main"

  choices="$(cat "$TEST_CAPTURE_DIR/workflow-choices.txt")"
  assert_contains "$choices" $'11\tStart Development Services\t.github/workflows/start-development-services.yml'
  assert_contains "$choices" "Rotate ECS Task Definitions"
  assert_not_contains "$choices" $'22\tCI'
  assert_not_contains "$choices" "Deploy to ECS"
  assert_contains "$(cat "$TEST_CAPTURE_DIR/fzf-args.txt")" "--with-nth 2,3"
  assert_contains "$(cat "$TEST_CAPTURE_DIR/gh-calls.txt")" "workflow run 11 --repo trade-tariff/trade-tariff-tools --ref main"
  [ ! -e "$TEST_CAPTURE_DIR/aws-called" ]
}

@test "ecs dispatch uses an explicit branch or tag for discovery and dispatch" {
  run "$repo_root/bin/ecs" dispatch --ref release-branch <<< y

  [ "$status" -eq 0 ]
  calls="$(cat "$TEST_CAPTURE_DIR/gh-calls.txt")"
  assert_contains "$calls" "workflow view 11 --repo trade-tariff/trade-tariff-tools --ref release-branch --yaml"
  assert_contains "$calls" "workflow run 11 --repo trade-tariff/trade-tariff-tools --ref release-branch"
  assert_not_contains "$calls" "repo view"
  assert_contains "$output" "Ref: release-branch"
}

@test "ecs dispatch skips workflows missing from the selected ref" {
  run env TEST_MISSING_WORKFLOW_ID=11 TEST_SELECT_ID=44 "$repo_root/bin/ecs" dispatch --ref release-branch <<< y

  [ "$status" -eq 0 ]
  assert_contains "$output" "Skipping workflow 'Start Development Services'"
  choices="$(cat "$TEST_CAPTURE_DIR/workflow-choices.txt")"
  assert_not_contains "$choices" "Start Development Services"
  assert_contains "$choices" "Rotate ECS Task Definitions"
  calls="$(cat "$TEST_CAPTURE_DIR/gh-calls.txt")"
  assert_contains "$calls" "workflow view 44 --repo trade-tariff/trade-tariff-tools --ref release-branch --yaml"
  assert_contains "$calls" "workflow run 44 --repo trade-tariff/trade-tariff-tools --ref release-branch"
}

@test "ecs dispatch leaves stdin available for GitHub workflow input prompts" {
  run env TEST_SELECT_ID=44 TEST_PROMPT_INPUT=true "$repo_root/bin/ecs" dispatch <<< $'y\n4'

  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_CAPTURE_DIR/workflow-input.txt")" = 4 ]
  assert_contains "$(cat "$TEST_CAPTURE_DIR/gh-calls.txt")" "workflow run 44"
}

@test "ecs dispatch requires affirmative confirmation" {
  run "$repo_root/bin/ecs" dispatch <<< ''

  [ "$status" -eq 0 ]
  assert_contains "$output" "Workflow dispatch cancelled"
  [ ! -e "$TEST_CAPTURE_DIR/dispatch-args.txt" ]
}

@test "ecs dispatch cancels without dispatching when stdin is closed" {
  run "$repo_root/bin/ecs" dispatch < /dev/null

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_CAPTURE_DIR/dispatch-args.txt" ]
}

@test "ecs dispatch cancels without dispatching when fuzzy selection is cancelled" {
  run env TEST_FZF_CANCEL=true "$repo_root/bin/ecs" dispatch <<< y

  [ "$status" -eq 0 ]
  [ ! -e "$TEST_CAPTURE_DIR/dispatch-args.txt" ]
}

@test "ecs dispatch reports when no active workflows are available" {
  run env TEST_NO_WORKFLOWS=true "$repo_root/bin/ecs" dispatch

  [ "$status" -eq 1 ]
  assert_contains "$output" "No active dispatch workflows found"
  [ ! -e "$TEST_CAPTURE_DIR/dispatch-args.txt" ]
  [ ! -e "$TEST_CAPTURE_DIR/fzf-args.txt" ]
}

@test "ecs dispatch stops when GitHub workflow discovery fails" {
  run env TEST_GH_FAILURE=list "$repo_root/bin/ecs" dispatch <<< y

  [ "$status" -eq 1 ]
  assert_contains "$output" "GitHub authentication failed"
  [ ! -e "$TEST_CAPTURE_DIR/dispatch-args.txt" ]
}

@test "ecs dispatch fails when no workflows can be read" {
  run env TEST_GH_FAILURE=view "$repo_root/bin/ecs" dispatch <<< y

  [ "$status" -eq 1 ]
  assert_contains "$output" "Cannot read workflow"
  assert_contains "$output" "No active dispatch workflows found"
  [ ! -e "$TEST_CAPTURE_DIR/dispatch-args.txt" ]
  [ ! -e "$TEST_CAPTURE_DIR/fzf-args.txt" ]
}

@test "ecs dispatch reports GitHub dispatch failures" {
  run env TEST_GH_FAILURE=run "$repo_root/bin/ecs" dispatch <<< y

  [ "$status" -eq 1 ]
  assert_contains "$output" "Workflow dispatch forbidden"
}

@test "ecs dispatch reports missing gh without checking AWS credentials" {
  mkdir -p "$tmpdir/minimal-bin"
  for dependency in basename jq fzf; do
    ln -s "$(command -v "$dependency")" "$tmpdir/minimal-bin/$dependency"
  done
  run env PATH="$tmpdir/minimal-bin" "$BASH" "$repo_root/bin/ecs" dispatch

  [ "$status" -eq 1 ]
  assert_contains "$output" "Missing required dependency: gh"
  [ ! -e "$TEST_CAPTURE_DIR/aws-called" ]
}

@test "ecs dispatch help does not check dependencies or credentials" {
  run "$repo_root/bin/ecs" dispatch --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: ecs dispatch"
  assert_contains "$output" "--ref"
  [ ! -e "$TEST_CAPTURE_DIR/gh-calls.txt" ]
  [ ! -e "$TEST_CAPTURE_DIR/aws-called" ]

  run "$repo_root/bin/ecs" --help
  [ "$status" -eq 0 ]
  assert_contains "$output" "dispatch"
}

@test "ecs dispatch rejects invalid arguments before contacting GitHub" {
  for arguments in --ref --unknown extra; do
    run "$repo_root/bin/ecs" dispatch "$arguments"
    [ "$status" -eq 2 ]
  done
  [ ! -e "$TEST_CAPTURE_DIR/gh-calls.txt" ]
}
