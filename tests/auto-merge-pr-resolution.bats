#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
  export GITHUB_OUTPUT="$tmpdir/output"
  export GITHUB_EVENT_PATH="$tmpdir/event.json"
  export GITHUB_EVENT_NAME=workflow_run
  export GITHUB_REPOSITORY=trade-tariff/example
  export GH_ARGS="$tmpdir/gh-args"
  export HEAD_SHA=0123456789abcdef0123456789abcdef01234567
  export GH_CANDIDATES='[{"number":42,"state":"open","head":{"sha":"0123456789abcdef0123456789abcdef01234567","repo":{"full_name":"trade-tariff/example"}},"base":{"repo":{"full_name":"trade-tariff/example"}}}]'
  resolver="$repo_root/.github/actions/resolve-auto-merge-pr/resolve-pull-request.sh"
  workflow="$repo_root/.github/workflows/auto-merge-low-risk.yml"
  jq -n --arg sha "$HEAD_SHA" '{workflow_run: {conclusion: "success", head_sha: $sha, head_branch: "feature/example", head_repository: {full_name: "trade-tariff/example"}, pull_requests: [{number: 42}]}}' > "$GITHUB_EVENT_PATH"

  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$GH_ARGS"
if [[ "${GH_LOOKUP_STATUS:-0}" -ne 0 ]]; then
  exit "$GH_LOOKUP_STATUS"
fi
if [[ "$*" == *'--slurp'* ]]; then
  # gh returns an array of pages and rejects --slurp combined with --jq.
  [[ "$*" != *'--jq'* ]] || exit 1
  if [[ -n "${GH_PAGES:-}" ]]; then
    printf '%s\n' "$GH_PAGES"
  else
    printf '[%s]\n' "$GH_CANDIDATES"
  fi
else
  printf '%s\n' "$GH_CANDIDATES"
fi
STUB
  chmod +x "$stub_bin/gh"
}

teardown() {
  rm -rf "$tmpdir"
}

update_event() {
  jq "$1" "$GITHUB_EVENT_PATH" > "$tmpdir/updated.json"
  mv "$tmpdir/updated.json" "$GITHUB_EVENT_PATH"
}

assert_skipped() {
  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=' ]
}

@test "workflow calls the resolver action with the App token and a scoped repository guard" {
  run grep -F 'uses: trade-tariff/trade-tariff-tools/.github/actions/resolve-auto-merge-pr@main' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'GH_TOKEN: ${{ steps.app-token.outputs.token }}' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "github.event_name != 'workflow_run' ||" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'github.event.workflow_run.head_repository.full_name == github.repository' "$workflow"
  [ "$status" -eq 0 ]
  action="$repo_root/.github/actions/resolve-auto-merge-pr/action.yml"
  run grep -F 'run: '\''"${{ github.action_path }}/resolve-pull-request.sh"'\' "$action"
  [ "$status" -eq 0 ]
  run grep -F 'value: ${{ steps.pr.outputs.number }}' "$action"
  [ "$status" -eq 0 ]
}

@test "successful workflow validates its associated PR by number" {
  run "$resolver"

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=42' ]
  [ "$(cat "$GH_ARGS")" = "$(printf '%s\n' api repos/trade-tariff/example/pulls/42 --jq '[.]')" ]
}

@test "backend push CI without event PRs resolves an exact-commit association" {
  update_event '.workflow_run.pull_requests = [] | .workflow_run.event = "push"'
  run "$resolver"

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=42' ]
  [ "$(cat "$GH_ARGS")" = "$(printf '%s\n' api --paginate --slurp "repos/trade-tariff/example/commits/$HEAD_SHA/pulls?per_page=100")" ]
}

@test "Dependabot push CI without event PRs uses the same exact-commit lookup" {
  update_event '.workflow_run.pull_requests = [] | .workflow_run.event = "push" | .workflow_run.head_branch = "dependabot/bundler/example-1.0" | .sender.login = "dependabot[bot]"'
  run "$resolver"

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=42' ]
}

@test "commit lookup checks all pages before selecting a unique PR" {
  update_event '.workflow_run.pull_requests = []'
  export GH_PAGES="$(jq -n --argjson candidates "$GH_CANDIDATES" '[[], $candidates]')"
  run "$resolver"

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=42' ]
}

@test "commit lookup rejects ambiguous PRs across pages" {
  update_event '.workflow_run.pull_requests = []'
  export GH_PAGES="$(jq -n --argjson candidates "$GH_CANDIDATES" '[$candidates, ($candidates | .[0].number = 43)]')"
  run "$resolver"

  assert_skipped
}

@test "missing event PR collection uses commit associations" {
  update_event 'del(.workflow_run.pull_requests)'
  run "$resolver"

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=42' ]
}

@test "fork workflow skips without a privileged PR lookup" {
  update_event '.workflow_run.head_repository.full_name = "outsider/example"'
  run "$resolver"

  assert_skipped
  [ ! -e "$GH_ARGS" ]
}

@test "missing workflow head repository skips without lookup" {
  update_event '.workflow_run.head_repository = null'
  run "$resolver"

  assert_skipped
  [ ! -e "$GH_ARGS" ]
}

@test "unsuccessful workflow skips PR lookup" {
  update_event '.workflow_run.conclusion = "failure"'
  run "$resolver"

  assert_skipped
  [ ! -e "$GH_ARGS" ]
}

@test "fork PR sharing an internal branch name is not eligible" {
  export GH_CANDIDATES="$(jq '.[0].head.repo.full_name = "outsider/example"' <<< "$GH_CANDIDATES")"
  run "$resolver"

  assert_skipped
}

@test "commit fallback rejects forks even when the run reports the base repository" {
  update_event '.workflow_run.pull_requests = []'
  export GH_CANDIDATES="$(jq '.[0].head.repo.full_name = "outsider/example"' <<< "$GH_CANDIDATES")"
  run "$resolver"

  assert_skipped
}

@test "fork association cannot hide a valid internal exact-head match" {
  update_event '.workflow_run.pull_requests = []'
  export GH_CANDIDATES="$(jq '. + [ (.[0] | .number = 43 | .head.repo.full_name = "outsider/example") ]' <<< "$GH_CANDIDATES")"
  run "$resolver"

  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'number=42' ]
}

@test "stale CI cannot select a PR with a newer head" {
  export GH_CANDIDATES="$(jq '.[0].head.sha = "newer-head"' <<< "$GH_CANDIDATES")"
  run "$resolver"

  assert_skipped
}

@test "commit fallback does not accept a commit merely contained in a PR" {
  update_event '.workflow_run.pull_requests = []'
  export GH_CANDIDATES="$(jq '.[0].head.sha = "newer-head"' <<< "$GH_CANDIDATES")"
  run "$resolver"

  assert_skipped
}

@test "closed PR is not eligible" {
  export GH_CANDIDATES="$(jq '.[0].state = "closed"' <<< "$GH_CANDIDATES")"
  run "$resolver"

  assert_skipped
}

@test "PR targeting another repository is not eligible" {
  export GH_CANDIDATES="$(jq '.[0].base.repo.full_name = "trade-tariff/other"' <<< "$GH_CANDIDATES")"
  run "$resolver"

  assert_skipped
}

@test "deleted PR head repository is not eligible" {
  export GH_CANDIDATES="$(jq '.[0].head.repo = null' <<< "$GH_CANDIDATES")"
  run "$resolver"

  assert_skipped
}

@test "multiple event associations skip rather than choosing the first" {
  update_event '.workflow_run.pull_requests += [{number: 43}]'
  run "$resolver"

  assert_skipped
  [ ! -e "$GH_ARGS" ]
}

@test "multiple exact-head commit associations skip rather than choosing the first" {
  update_event '.workflow_run.pull_requests = []'
  export GH_CANDIDATES="$(jq '. + [ (.[0] | .number = 43) ]' <<< "$GH_CANDIDATES")"
  run "$resolver"

  assert_skipped
}

@test "missing commit association skips auto-merge" {
  update_event '.workflow_run.pull_requests = []'
  export GH_CANDIDATES='[]'
  run "$resolver"

  assert_skipped
}

@test "API failure cannot produce a merge candidate" {
  export GH_LOOKUP_STATUS=1
  run "$resolver"

  [ "$status" -ne 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "malformed API response cannot produce a merge candidate" {
  export GH_CANDIDATES='not JSON'
  run "$resolver"

  [ "$status" -ne 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "invalid or missing run SHA skips without lookup" {
  update_event '.workflow_run.head_sha = "../../other"'
  run "$resolver"

  assert_skipped
  [ ! -e "$GH_ARGS" ]
}

@test "PR and review events use their PR number without a lookup" {
  update_event '.pull_request.number = 42'
  for GITHUB_EVENT_NAME in pull_request pull_request_review; do
    export GITHUB_EVENT_NAME
    rm -f "$GITHUB_OUTPUT"
    run "$resolver"

    [ "$status" -eq 0 ]
    [ "$(cat "$GITHUB_OUTPUT")" = 'number=42' ]
    [ ! -e "$GH_ARGS" ]
  done
}

@test "unsupported event skips without lookup" {
  export GITHUB_EVENT_NAME=push
  run "$resolver"

  assert_skipped
  [ ! -e "$GH_ARGS" ]
}

@test "missing required environment fails with usage error" {
  unset GITHUB_REPOSITORY
  run "$resolver"

  [ "$status" -eq 2 ]
  assert_contains "$output" 'Missing required environment variable: GITHUB_REPOSITORY'
}

@test "resolver help does not require runner environment" {
  unset GITHUB_REPOSITORY
  run "$resolver" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" 'Resolve one internal pull request without matching branch names.'
}
