#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
  export GH_CAPTURE_FILE="$tmpdir/gh-edit-args.txt"

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
  jq -r "$query" <<< "$GH_REVIEW_REQUESTS_JSON"
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "edit" ]]; then
  printf '%s\n' "$@" > "$GH_CAPTURE_FILE"
  exit "${GH_EDIT_STATUS:-0}"
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
  run grep -Fx "copilot" "$GH_CAPTURE_FILE"
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
  export GH_REVIEW_REQUESTS_JSON='{"reviews":[{"author":{"login":"copilot-pull-request-reviewer"},"body":"Copilot was unable to review this pull request because the user who requested the review has reached their quota limit.","submittedAt":"2026-07-16T15:47:00Z"}]}'

  run "$repo_root/.github/actions/auto-merge-low-risk/check-copilot-review-gate.sh" \
    --repo trade-tariff/example \
    --pr 42

  [ "$status" -eq 1 ]
  assert_contains "$output" "Copilot could not review PR #42 because its review quota is exhausted; blocking auto-merge."
}

@test "reusable workflow only handles Copilot review events" {
  workflow="$repo_root/.github/workflows/auto-merge-low-risk.yml"

  run grep -F "github.event_name != 'pull_request_review' ||" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "contains(github.event.review.user.login, 'copilot')" "$workflow"
  [ "$status" -eq 0 ]
}
