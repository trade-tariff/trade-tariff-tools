#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  action_dir="$repo_root/.github/actions/close-stale-pull-requests"
  close_script="$action_dir/close-stale-pull-requests.sh"
  branches_script="$action_dir/delete-stale-branches.sh"

  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "pr" && "$2" == "list" ]]; then
  if [[ "$*" == *"headRefName"* ]]; then
    printf '%s\n' 'open-pr-branch'
    exit 0
  fi

  if [[ -n "${GH_NO_PULL_REQUESTS:-}" ]]; then
    printf '%s\n' '[]'
    exit 0
  fi

  fresh_date="$(date -u -d '1 day ago' '+%Y-%m-%dT%H:%M:%SZ')"
  printf '[{"number":10,"updatedAt":"2026-05-01T12:00:00Z","labels":[]},{"number":11,"updatedAt":"2026-05-01T12:00:00Z","labels":[{"name":"keep"}]},{"number":12,"updatedAt":"%s","labels":[]},{"number":13,"updatedAt":"2026-05-01T12:00:00Z","labels":[{"name":"keep"},{"name":"dependencies"}]}]\n' "$fresh_date"
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "close" ]]; then
  printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/gh-close-commands.txt"
  exit 0
fi

if [[ "$1" == "repo" && "$2" == "view" ]]; then
  printf '%s\n' 'main'
  exit 0
fi

if [[ "$1" == "api" && "$2" == "repos/trade-tariff/example/branches" ]]; then
  printf '%s\n' \
    '{"name":"main","protected":false,"commit":{"sha":"sha-main"}}' \
    '{"name":"protected-branch","protected":true,"commit":{"sha":"sha-protected"}}' \
    '{"name":"open-pr-branch","protected":false,"commit":{"sha":"sha-open"}}' \
    '{"name":"fresh-branch","protected":false,"commit":{"sha":"sha-fresh"}}' \
    '{"name":"stale-branch","protected":false,"commit":{"sha":"sha-stale"}}'
  exit 0
fi

if [[ "$1" == "api" && "$2" == "repos/trade-tariff/example/commits/sha-fresh" ]]; then
  fresh_date="$(date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%SZ')"
  printf '{"commit":{"committer":{"date":"%s"}}}\n' "$fresh_date"
  exit 0
fi

if [[ "$1" == "api" && "$2" == "repos/trade-tariff/example/commits/sha-stale" ]]; then
  printf '%s\n' '{"commit":{"committer":{"date":"2026-05-01T12:00:00Z"}}}'
  exit 0
fi

if [[ "$1" == "api" && "$2" == "--method" && "$3" == "DELETE" ]]; then
  printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/gh-delete-commands.txt"
  exit 0
fi

echo "unexpected gh command: $*" >&2
exit 1
STUB
  chmod +x "$stub_bin/gh"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "close stale lists pull requests that would be closed in dry run" {
  run env REPO="trade-tariff/example" STALE_DAYS="14" KEEP_LABEL="keep" DRY_RUN="true" "$close_script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "[DRY RUN] Would close PR #10"
  assert_contains "$output" "Skipping PR #11 (label: keep)"
  assert_contains "$output" "Summary: closed=0, skipped_keep=2, skipped_fresh=1"
  [ ! -f "$tmpdir/gh-close-commands.txt" ]
}

@test "close stale closes the pull request and deletes its branch" {
  run env REPO="trade-tariff/example" STALE_DAYS="14" KEEP_LABEL="keep" DRY_RUN="false" "$close_script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "Closed PR #10"
  assert_contains "$output" "Summary: closed=1, skipped_keep=2, skipped_fresh=1"
  close_commands="$(cat "$tmpdir/gh-close-commands.txt")"
  assert_contains "$close_commands" "pr close 10 --repo trade-tariff/example"
  assert_contains "$close_commands" "--delete-branch"
  assert_not_contains "$close_commands" "pr close 11"
  assert_not_contains "$close_commands" "pr close 12"
  assert_not_contains "$close_commands" "pr close 13"
}

@test "close stale keeps a pull request when the keep label is not the last label" {
  run env REPO="trade-tariff/example" STALE_DAYS="14" KEEP_LABEL="keep" DRY_RUN="true" "$close_script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "Skipping PR #13 (label: keep)"
  assert_not_contains "$output" "Would close PR #13"
}

@test "close stale exits cleanly with no open pull requests" {
  run env GH_NO_PULL_REQUESTS=1 REPO="trade-tariff/example" STALE_DAYS="14" KEEP_LABEL="keep" DRY_RUN="false" "$close_script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "No open pull requests."
}

@test "close stale requires its environment" {
  run env STALE_DAYS="14" KEEP_LABEL="keep" DRY_RUN="true" "$close_script"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: REPO"
}

@test "close stale prints help" {
  run "$close_script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: close-stale-pull-requests.sh"
}

@test "delete stale branches deletes only stale branches without open pull requests" {
  run env REPO="trade-tariff/example" STALE_DAYS="14" DRY_RUN="false" "$branches_script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "Skipping branch main (default branch)"
  assert_contains "$output" "Skipping branch protected-branch (protected)"
  assert_contains "$output" "Skipping branch open-pr-branch (open pull request)"
  assert_contains "$output" "Deleted branch stale-branch"
  assert_contains "$output" "Summary: deleted=1, skipped_default=1, skipped_protected=1, skipped_open_pr=1, skipped_fresh=1"
  delete_commands="$(cat "$tmpdir/gh-delete-commands.txt")"
  assert_contains "$delete_commands" "api --method DELETE repos/trade-tariff/example/git/refs/heads/stale-branch"
  assert_not_contains "$delete_commands" "main"
  assert_not_contains "$delete_commands" "protected-branch"
  assert_not_contains "$delete_commands" "open-pr-branch"
  assert_not_contains "$delete_commands" "fresh-branch"
}

@test "delete stale branches only lists branches in dry run" {
  run env REPO="trade-tariff/example" STALE_DAYS="14" DRY_RUN="true" "$branches_script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "[DRY RUN] Would delete branch stale-branch"
  [ ! -f "$tmpdir/gh-delete-commands.txt" ]
}

@test "delete stale branches requires its environment" {
  run env REPO="trade-tariff/example" DRY_RUN="true" "$branches_script"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: STALE_DAYS"
}

@test "delete stale branches prints help" {
  run "$branches_script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: delete-stale-branches.sh"
}

@test "reusable workflow delegates to the close-stale-pull-requests action" {
  workflow="$repo_root/.github/workflows/close-stale-pull-requests-reusable.yml"

  run grep -F "uses: trade-tariff/trade-tariff-tools/.github/actions/close-stale-pull-requests@main" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'stale_days: ${{ inputs.stale_days }}' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'keep_label: ${{ inputs.keep_label }}' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'dry_run: ${{ inputs.dry_run }}' "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "run: |" "$workflow"
  [ "$status" -ne 0 ]
}

@test "close-stale-pull-requests action calls both scripts" {
  action="$action_dir/action.yml"

  run grep -F "run: '\"\${{ github.action_path }}/close-stale-pull-requests.sh\"'" "$action"
  [ "$status" -eq 0 ]
  run grep -F "run: '\"\${{ github.action_path }}/delete-stale-branches.sh\"'" "$action"
  [ "$status" -eq 0 ]
  run grep -F 'GH_TOKEN: ${{ inputs.github-token }}' "$action"
  [ "$status" -eq 0 ]
  run grep -F 'KEEP_LABEL: ${{ inputs.keep_label }}' "$action"
  [ "$status" -eq 0 ]
}
