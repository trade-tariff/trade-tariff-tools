#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
  export GH_CAPTURE_FILE="$tmpdir/gh-edit-args.txt"
  export GH_API_CAPTURE_FILE="$tmpdir/gh-api-args.txt"
  export GH_MERGE_CAPTURE_FILE="$tmpdir/gh-merge-args.txt"

  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  query=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-q" ]]; then
      query="$2"
      break
    fi
    shift
  done
  if [[ -n "$query" ]]; then
    jq -r "$query" <<< "$GH_REVIEW_REQUESTS_JSON"
  else
    printf '%s\n' "$GH_REVIEW_REQUESTS_JSON"
  fi
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "edit" ]]; then
  printf '%s\n' "$@" > "$GH_CAPTURE_FILE"
  exit "${GH_EDIT_STATUS:-0}"
fi

if [[ "$1" == "pr" && "$2" == "merge" ]]; then
  printf '%s\n' "$@" > "$GH_MERGE_CAPTURE_FILE"
  if [[ -n "${ORCHESTRATION_LOG:-}" ]]; then
    printf 'merge %s\n' "$*" >> "$ORCHESTRATION_LOG"
  fi
  exit "${GH_MERGE_STATUS:-0}"
fi

if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  if [[ "${GH_API_STATUS:-0}" -ne 0 ]]; then
    printf '%s\n' "${GH_API_OUTPUT:-GraphQL request failed}" >&2
    exit "$GH_API_STATUS"
  fi
  if [[ -n "${GH_THREADS_JSON:-}" ]]; then
    printf '%s\n' "$GH_THREADS_JSON"
  else
    printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
  fi
  exit 0
fi

if [[ "$1" == "api" ]]; then
  printf '%s\n' "$@" > "$GH_API_CAPTURE_FILE"
  exit "${GH_API_STATUS:-0}"
fi

if [[ "$1" == "run" && "$2" == "list" ]]; then
  printf '%s\n' "${GH_RUNS_JSON:-[]}"
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

@test "requests Copilot when a team review request has no login" {
  export GH_REVIEW_REQUESTS_JSON='{"reviewRequests":[{"__typename":"Team","name":"trade-tariff-core"}]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/request-copilot-review.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 0 ]
  assert_contains "$output" "Requesting Copilot code review for PR #42"
  run grep -Fx -- "--add-reviewer" "$GH_CAPTURE_FILE"
  [ "$status" -eq 0 ]
  run grep -Fx "copilot-pull-request-reviewer" "$GH_CAPTURE_FILE"
  [ "$status" -eq 0 ]
}

@test "does not treat an impostor account as an outstanding Copilot request" {
  export GH_REVIEW_REQUESTS_JSON='{"reviewRequests":[{"__typename":"User","login":"helpful-copilot-reviewer"}]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/request-copilot-review.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 0 ]
  assert_contains "$output" "Requesting Copilot code review for PR #42"
  run grep -Fx "copilot-pull-request-reviewer" "$GH_CAPTURE_FILE"
  [ "$status" -eq 0 ]
}

@test "does not duplicate an outstanding Copilot review request" {
  export GH_REVIEW_REQUESTS_JSON='{"reviewRequests":[{"__typename":"User","login":"copilot-pull-request-reviewer[bot]"}]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/request-copilot-review.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 0 ]
  assert_contains "$output" "Copilot review already requested on PR #42."
  [ ! -e "$GH_CAPTURE_FILE" ]
}

@test "warns and succeeds when GitHub rejects the Copilot request" {
  export GH_REVIEW_REQUESTS_JSON='{"reviewRequests":[]}'
  export GH_EDIT_STATUS=1

  run "$repo_root/.github/actions/auto-merge-low-risk/request-copilot-review.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 0 ]
  assert_contains "$output" "::warning::Unable to request Copilot code review for PR #42; auto-merge will retry after a review is available."
}

@test "blocks auto-merge when Copilot cannot review because its quota is exhausted" {
  export GH_REVIEW_REQUESTS_JSON='{"headRefOid":"current-head","reviews":[{"author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"current-head"},"body":"Copilot was unable to review this pull request because the user who requested the review has reached their quota limit.","submittedAt":"2026-07-16T15:47:00Z"}]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-copilot-review-gate.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 1 ]
  assert_contains "$output" "Copilot could not review PR #42 because its review quota is exhausted; blocking auto-merge."
  assert_contains "$output" "GitHub reports that the user who requested the review has reached their quota or budget limit."
}

@test "Copilot gate help describes every exit-one condition as blocking" {
  run "$repo_root/.github/actions/auto-merge-low-risk/check-copilot-review-gate.sh" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Exits 1 when a Copilot review requirement blocks auto-merge."
}

@test "requires Copilot to review the current pull request head" {
  export GH_REVIEW_REQUESTS_JSON='{"headRefOid":"current-head","reviews":[{"author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"previous-head"},"body":"","submittedAt":"2026-07-20T08:41:33Z"}]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-copilot-review-gate.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 2 ]
  assert_contains "$output" "PR #42 has not been reviewed by Copilot at its current head."
}

@test "does not accept an impostor account as Copilot" {
  export GH_REVIEW_REQUESTS_JSON='{"headRefOid":"current-head","reviews":[{"author":{"login":"helpful-copilot-reviewer"},"commit":{"oid":"current-head"},"body":"","submittedAt":"2026-07-20T08:41:33Z"}]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-copilot-review-gate.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 2 ]
  assert_contains "$output" "PR #42 has not been reviewed by Copilot at its current head."
}

@test "disarms an existing auto-merge request before rejecting a stale review" {
  export GH_REVIEW_REQUESTS_JSON='{"autoMergeRequest":{"enabledAt":"2026-07-20T08:40:00Z"},"headRefOid":"new-head","reviews":[{"author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"old-head"},"body":"","submittedAt":"2026-07-20T08:41:33Z"}]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/disable-auto-merge.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --merge-method rebase
  [ "$status" -eq 0 ]
  run grep -Fx -- "--disable-auto" "$GH_MERGE_CAPTURE_FILE"
  [ "$status" -eq 0 ]

  run "$repo_root/.github/actions/auto-merge-low-risk/check-copilot-review-gate.sh" \
    --repo trade-tariff/example \
    --pr 42
  [ "$status" -eq 2 ]
  assert_contains "$output" "PR #42 has not been reviewed by Copilot at its current head."
}

@test "disable helper documents its accepted merge methods" {
  run "$repo_root/.github/actions/auto-merge-low-risk/disable-auto-merge.sh" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "--merge-method <merge|squash|rebase>"
}

@test "disable helper rejects an invalid merge method before calling GitHub" {
  export GH_REVIEW_REQUESTS_JSON='{"autoMergeRequest":{"enabledAt":"2026-07-20T08:40:00Z"}}'

  run "$repo_root/.github/actions/auto-merge-low-risk/disable-auto-merge.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --merge-method invalid

  [ "$status" -eq 2 ]
  assert_contains "$output" "Invalid merge method: invalid"
  [ ! -e "$GH_MERGE_CAPTURE_FILE" ]
}

@test "Copilot gate rejects a pull request head change during evaluation" {
  export GH_REVIEW_REQUESTS_JSON='{"headRefOid":"new-head","reviews":[{"author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"new-head"},"body":"","submittedAt":"2026-07-20T08:45:35Z"}]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-copilot-review-gate.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --head expected-head

  [ "$status" -eq 1 ]
  assert_contains "$output" "PR #42 head changed from expected-head to new-head; blocking auto-merge."
}

@test "fails closed when review threads cannot be read" {
  export GH_REVIEW_REQUESTS_JSON='{"headRefOid":"current-head","reviews":[{"author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"current-head"},"body":"","submittedAt":"2026-07-20T08:45:35Z"}]}'
  export GH_API_STATUS=1
  export GH_API_OUTPUT='GraphQL: Resource not accessible by personal access token'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-copilot-review-gate.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 1 ]
  assert_contains "$output" "Insufficient token permissions to check Copilot review threads; blocking auto-merge."
}

@test "passes when Copilot reviewed the current head and has no unresolved threads" {
  export GH_REVIEW_REQUESTS_JSON='{"headRefOid":"current-head","reviews":[{"author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"current-head"},"body":"","submittedAt":"2026-07-20T08:45:35Z"}]}'
  export GH_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-copilot-review-gate.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 0 ]
}

@test "blocks auto-merge when a Copilot thread is unresolved" {
  export GH_REVIEW_REQUESTS_JSON='{"headRefOid":"current-head","reviews":[{"author":{"login":"copilot-pull-request-reviewer"},"commit":{"oid":"current-head"},"body":"","submittedAt":"2026-07-20T08:45:35Z"}]}'
  export GH_THREADS_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"thread-1","isResolved":false,"isOutdated":false,"path":"action.yml","comments":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer"}}]}}]}}}}}'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-copilot-review-gate.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 1 ]
  assert_contains "$output" "1 unresolved Copilot review thread(s) on PR #42:"
}

@test "blocks auto-merge while the pull request is draft" {
  export GH_REVIEW_REQUESTS_JSON='{"isDraft":true,"headRefOid":"current-head","statusCheckRollup":[]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-pull-request-state-gate.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --workflow ci.yml

  [ "$status" -eq 1 ]
  assert_contains "$output" "PR #42 is still a draft; blocking auto-merge."
}

@test "state gate rejects a pull request head change during evaluation" {
  export GH_REVIEW_REQUESTS_JSON='{"isDraft":false,"headRefOid":"new-head","statusCheckRollup":[]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-pull-request-state-gate.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --workflow ci.yml \
    --head expected-head

  [ "$status" -eq 1 ]
  assert_contains "$output" "PR #42 head changed from expected-head to new-head; blocking auto-merge."
}

@test "approval gate refuses to approve a different pull request head" {
  export GH_REVIEW_REQUESTS_JSON='{"isDraft":false,"headRefOid":"new-head"}'

  run "$repo_root/.github/actions/auto-merge-low-risk/approve-pull-request.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --head expected-head

  [ "$status" -eq 1 ]
  assert_contains "$output" "PR #42 head changed from expected-head to new-head; refusing approval."
  [ ! -e "$GH_API_CAPTURE_FILE" ]
}

@test "approval gate refuses to approve a draft pull request" {
  export GH_REVIEW_REQUESTS_JSON='{"isDraft":true,"headRefOid":"expected-head"}'

  run "$repo_root/.github/actions/auto-merge-low-risk/approve-pull-request.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --head expected-head

  [ "$status" -eq 1 ]
  assert_contains "$output" "PR #42 is a draft; refusing approval."
  [ ! -e "$GH_API_CAPTURE_FILE" ]
}

@test "approval is attached to the expected pull request head" {
  export GH_REVIEW_REQUESTS_JSON='{"isDraft":false,"headRefOid":"expected-head"}'

  run "$repo_root/.github/actions/auto-merge-low-risk/approve-pull-request.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --head expected-head

  [ "$status" -eq 0 ]
  run grep -Fx -- "repos/trade-tariff/example/pulls/42/reviews" "$GH_API_CAPTURE_FILE"
  [ "$status" -eq 0 ]
  run grep -Fx -- "event=APPROVE" "$GH_API_CAPTURE_FILE"
  [ "$status" -eq 0 ]
  run grep -Fx -- "commit_id=expected-head" "$GH_API_CAPTURE_FILE"
  [ "$status" -eq 0 ]
}

@test "requires a CI run for the current pull request head" {
  export GH_REVIEW_REQUESTS_JSON='{"isDraft":false,"headRefOid":"current-head","statusCheckRollup":[]}'
  export GH_RUNS_JSON='[{"headSha":"previous-head","status":"completed","conclusion":"success","createdAt":"2026-07-20T08:40:00Z"}]'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-pull-request-state-gate.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --workflow ci.yml

  [ "$status" -eq 1 ]
  assert_contains "$output" "No ci.yml run exists for the current head of PR #42; blocking auto-merge."
}

@test "blocks auto-merge while current-head CI is pending" {
  export GH_REVIEW_REQUESTS_JSON='{"isDraft":false,"headRefOid":"current-head","statusCheckRollup":[]}'
  export GH_RUNS_JSON='[{"headSha":"current-head","status":"in_progress","conclusion":"","createdAt":"2026-07-20T08:43:10Z"}]'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-pull-request-state-gate.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --workflow ci.yml

  [ "$status" -eq 1 ]
  assert_contains "$output" "The current-head ci.yml run for PR #42 is in_progress; blocking auto-merge."
}

@test "blocks auto-merge when current-head CI is unsuccessful" {
  export GH_REVIEW_REQUESTS_JSON='{"isDraft":false,"headRefOid":"current-head","statusCheckRollup":[]}'
  export GH_RUNS_JSON='[{"headSha":"current-head","status":"completed","conclusion":"failure","createdAt":"2026-07-20T08:43:10Z"}]'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-pull-request-state-gate.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --workflow ci.yml

  [ "$status" -eq 1 ]
  assert_contains "$output" "The current-head ci.yml run for PR #42 concluded failure; blocking auto-merge."
}

@test "blocks auto-merge while another current-head workflow is pending" {
  export GH_REVIEW_REQUESTS_JSON='{"isDraft":false,"headRefOid":"current-head","statusCheckRollup":[{"__typename":"CheckRun","name":"Analyze (ruby)","workflowName":"CodeQL Advanced","status":"IN_PROGRESS","conclusion":""},{"__typename":"CheckRun","name":"auto-merge / auto-merge","workflowName":"Auto-merge low-risk PRs","status":"IN_PROGRESS","conclusion":""}]}'
  export GH_RUNS_JSON='[{"headSha":"current-head","status":"completed","conclusion":"success","createdAt":"2026-07-20T08:43:10Z"}]'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-pull-request-state-gate.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --workflow ci.yml

  [ "$status" -eq 1 ]
  assert_contains "$output" "1 current-head check has not completed successfully for PR #42:"
  assert_contains "$output" "CodeQL Advanced / Analyze (ruby): IN_PROGRESS"
}

@test "passes when the pull request is ready and every current-head check is green" {
  export GH_REVIEW_REQUESTS_JSON='{"isDraft":false,"headRefOid":"current-head","statusCheckRollup":[{"__typename":"CheckRun","name":"lint","workflowName":"ci","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"deploy","workflowName":"Deploy to development","status":"COMPLETED","conclusion":"SKIPPED"},{"__typename":"CheckRun","name":"CodeQL","workflowName":"","status":"COMPLETED","conclusion":"NEUTRAL"},{"__typename":"CheckRun","name":"auto-merge / auto-merge","workflowName":"Auto-merge low-risk PRs","status":"IN_PROGRESS","conclusion":""}]}'
  export GH_RUNS_JSON='[{"headSha":"current-head","status":"completed","conclusion":"success","createdAt":"2026-07-20T08:43:10Z"}]'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-pull-request-state-gate.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --workflow ci.yml

  [ "$status" -eq 0 ]
}

@test "reusable workflow wires the current pull request state gate" {
  action="$repo_root/.github/actions/auto-merge-low-risk/action.yml"
  orchestrator="$repo_root/.github/actions/auto-merge-low-risk/auto-merge.sh"
  workflow="$repo_root/.github/workflows/auto-merge-low-risk.yml"
  ci_workflow="$repo_root/.github/workflows/ci.yml"

  run grep -F "required-workflow:" "$action"
  [ "$status" -eq 0 ]
  run grep -F 'auto-merge.sh' "$action"
  [ "$status" -eq 0 ]
  run grep -F 'check-pull-request-state-gate.sh' "$orchestrator"
  [ "$status" -eq 0 ]
  run grep -F 'disable-auto-merge.sh' "$orchestrator"
  [ "$status" -eq 0 ]
  run grep -F 'approve-pull-request.sh' "$orchestrator"
  [ "$status" -eq 0 ]
  run grep -F 'gh pr review' "$orchestrator"
  [ "$status" -ne 0 ]
  run grep -F -- '--head "$expected_head"' "$orchestrator"
  [ "$status" -eq 0 ]
  run grep -F -- '--match-head-commit "$expected_head"' "$orchestrator"
  [ "$status" -eq 0 ]
  run grep -F 'required-workflow: ${{ inputs.required-workflow }}' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F '.github/actions/auto-merge-low-risk/check-pull-request-state-gate.sh' "$ci_workflow"
  [ "$status" -eq 0 ]
  run grep -F '.github/actions/auto-merge-low-risk/disable-auto-merge.sh' "$ci_workflow"
  [ "$status" -eq 0 ]
  run grep -F '.github/actions/auto-merge-low-risk/approve-pull-request.sh' "$ci_workflow"
  [ "$status" -eq 0 ]
}

make_orchestration_harness() {
  harness="$tmpdir/action"
  mkdir -p "$harness"
  cp "$repo_root/.github/actions/auto-merge-low-risk/auto-merge.sh" "$harness/auto-merge.sh"
  chmod +x "$harness/auto-merge.sh"
  export ORCHESTRATION_LOG="$tmpdir/orchestration.log"

  for helper in disable-auto-merge check-copilot-review-gate check-pull-request-state-gate request-copilot-review approve-pull-request; do
    cat > "$harness/$helper.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
name="$(basename "$0" .sh)"
printf '%s %s\n' "$name" "$*" >> "$ORCHESTRATION_LOG"
case "$name" in
  check-copilot-review-gate) exit "${COPILOT_GATE_STATUS:-0}" ;;
  check-pull-request-state-gate) exit "${STATE_GATE_STATUS:-0}" ;;
esac
STUB
    chmod +x "$harness/$helper.sh"
  done
}

run_orchestration() {
  run "$harness/auto-merge.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --label low-risk \
    --merge-method squash \
    --required-workflow ci.yml
}

@test "orchestration treats the enabling label as a literal string" {
  make_orchestration_harness
  export GH_REVIEW_REQUESTS_JSON='{"labels":[{"name":"lowXrisk"}],"headRefOid":"expected-head"}'

  run "$harness/auto-merge.sh" \
    --repo trade-tariff/example \
    --pr 42 \
    --label 'low.risk' \
    --merge-method squash \
    --required-workflow ci.yml

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$ORCHESTRATION_LOG")" -eq 1 ]
  assert_contains "$output" "does not have the low.risk label; skipping."
}

@test "orchestration disarms first and never approves or merges without a current-head review" {
  make_orchestration_harness
  export GH_REVIEW_REQUESTS_JSON='{"labels":[{"name":"low-risk"}],"headRefOid":"expected-head"}'
  export COPILOT_GATE_STATUS=2

  run_orchestration

  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$ORCHESTRATION_LOG")" = "disable-auto-merge --repo trade-tariff/example --pr 42 --merge-method squash" ]
  run grep -E '^(approve-pull-request|merge) ' "$ORCHESTRATION_LOG"
  [ "$status" -ne 0 ]
}

@test "orchestration never approves or merges when pull request state or checks fail" {
  make_orchestration_harness
  export GH_REVIEW_REQUESTS_JSON='{"labels":[{"name":"low-risk"}],"headRefOid":"expected-head"}'
  export COPILOT_GATE_STATUS=0
  export STATE_GATE_STATUS=1

  run_orchestration

  [ "$status" -eq 0 ]
  run grep -E '^(approve-pull-request|merge) ' "$ORCHESTRATION_LOG"
  [ "$status" -ne 0 ]
}

@test "orchestration approves before merging and binds every gate to one head" {
  make_orchestration_harness
  export GH_REVIEW_REQUESTS_JSON='{"labels":[{"name":"low-risk"}],"headRefOid":"expected-head"}'
  export COPILOT_GATE_STATUS=0
  export STATE_GATE_STATUS=0

  run_orchestration

  [ "$status" -eq 0 ]
  expected="$tmpdir/expected.log"
  cat > "$expected" <<'EOF'
disable-auto-merge --repo trade-tariff/example --pr 42 --merge-method squash
check-copilot-review-gate --repo trade-tariff/example --pr 42 --head expected-head
check-pull-request-state-gate --repo trade-tariff/example --pr 42 --workflow ci.yml --head expected-head
approve-pull-request --repo trade-tariff/example --pr 42 --head expected-head
merge pr merge 42 --repo trade-tariff/example --squash --match-head-commit expected-head
EOF
  run diff -u "$expected" "$ORCHESTRATION_LOG"
  [ "$status" -eq 0 ]
}

@test "reusable workflow only handles Copilot review events" {
  workflow="$repo_root/.github/workflows/auto-merge-low-risk.yml"

  run grep -F "github.event_name != 'pull_request_review' ||" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "github.event.review.user.login == 'copilot-pull-request-reviewer'" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "contains(github.event.review.user.login, 'copilot')" "$workflow"
  [ "$status" -ne 0 ]
}

@test "reusable workflow can read exact-head workflow runs" {
  workflow="$repo_root/.github/workflows/auto-merge-low-risk.yml"

  run grep -F "actions: read" "$workflow"
  [ "$status" -eq 0 ]
}
