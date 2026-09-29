#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
  script="$repo_root/.github/actions/auto-merge-low-risk/check-dependabot-pull-request.sh"
  export GH_PR_AUTHOR="dependabot[bot]"
  export GH_COMMITS_JSON='[{"sha":"expected-head","author":{"login":"dependabot[bot]"},"committer":{"login":"web-flow"},"commit":{"verification":{"verified":true}}}]'

  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "api" ]]; then
  if [[ "${GH_API_STATUS:-0}" -ne 0 ]]; then
    echo "gh api failed" >&2
    exit "$GH_API_STATUS"
  fi
  endpoint=""
  query=""
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jq) query="$2"; shift 2 ;;
      --paginate) shift ;;
      *) endpoint="$1"; shift ;;
    esac
  done
  case "$endpoint" in
    */pulls/42) jq -r "$query" <<< "{\"user\":{\"login\":\"$GH_PR_AUTHOR\"}}" ;;
    */pulls/42/commits) jq -r "$query" <<< "$GH_COMMITS_JSON" ;;
    *) echo "unexpected endpoint: $endpoint" >&2; exit 1 ;;
  esac
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
STUB
  chmod +x "$stub_bin/gh"
}

teardown() {
  rm -rf "$tmpdir"
}

run_check() {
  run "$script" --repo trade-tariff/example --pr 42 --head expected-head
}

@test "passes when Dependabot authored the pull request and every commit" {
  run_check

  [ "$status" -eq 0 ]
  assert_contains "$output" "PR #42 contains only Dependabot commits"
}

@test "fails when a person authored the pull request" {
  export GH_PR_AUTHOR="someone"

  run_check

  [ "$status" -eq 1 ]
  assert_contains "$output" "PR #42 is not authored by dependabot[bot]"
}

@test "does not accept an impostor account as Dependabot" {
  export GH_PR_AUTHOR="dependabot"

  run_check

  [ "$status" -eq 1 ]
}

@test "fails when a person pushed a commit to the Dependabot branch" {
  export GH_COMMITS_JSON='[
    {"sha":"first","author":{"login":"dependabot[bot]"},"committer":{"login":"web-flow"},"commit":{"verification":{"verified":true}}},
    {"sha":"expected-head","author":{"login":"someone"},"committer":{"login":"someone"},"commit":{"verification":{"verified":true}}}
  ]'

  run_check

  [ "$status" -eq 1 ]
  assert_contains "$output" "PR #42 has commits that Dependabot did not author"
}

@test "fails when a commit uses the Dependabot author without a GitHub signature" {
  export GH_COMMITS_JSON='[{"sha":"expected-head","author":{"login":"dependabot[bot]"},"committer":{"login":"someone"},"commit":{"verification":{"verified":false}}}]'

  run_check

  [ "$status" -eq 1 ]
  assert_contains "$output" "PR #42 has commits that Dependabot did not author"
}

@test "fails when a commit author does not map to a GitHub account" {
  export GH_COMMITS_JSON='[{"sha":"expected-head","author":null,"committer":null,"commit":{"verification":{"verified":false}}}]'

  run_check

  [ "$status" -eq 1 ]
}

@test "fails when the last commit is not the expected head" {
  export GH_COMMITS_JSON='[{"sha":"new-head","author":{"login":"dependabot[bot]"},"committer":{"login":"web-flow"},"commit":{"verification":{"verified":true}}}]'

  run_check

  [ "$status" -eq 1 ]
  assert_contains "$output" "PR #42 head changed from expected-head to new-head"
}

@test "fails when the pull request has no commits" {
  export GH_COMMITS_JSON='[]'

  run_check

  [ "$status" -eq 1 ]
}

@test "exits 3 when GitHub cannot be read" {
  export GH_API_STATUS=1

  run_check

  [ "$status" -eq 3 ]
  assert_contains "$output" "Unable to read PR #42"
}

@test "rejects missing arguments" {
  run "$script" --repo trade-tariff/example --pr 42

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required arguments."
}

@test "help describes the exit codes" {
  run "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: check-dependabot-pull-request.sh"
  assert_contains "$output" "Exits 0 when"
  assert_contains "$output" "Exits 1 when"
  assert_contains "$output" "Exits 3 when"
}

@test "ci runs syntax checks for the Dependabot helper" {
  [ -f "$repo_root/.github/actions/auto-merge-low-risk/check-dependabot-pull-request.sh" ]

  run grep -F 'for file in bin/* scripts/*.sh scripts/lib/*.sh .github/actions/*/*.sh tests/test_helper.bash; do' "$repo_root/.github/workflows/ci.yml"
  [ "$status" -eq 0 ]
}

@test "reusable workflow skips Dependabot events that receive no Actions secrets" {
  workflow="$repo_root/.github/workflows/auto-merge-low-risk.yml"

  run grep -F "(github.event_name == 'workflow_run' || github.actor != 'dependabot[bot]')" "$workflow"
  [ "$status" -eq 0 ]
}
