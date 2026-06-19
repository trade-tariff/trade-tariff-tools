#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path

  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "pr" && "$2" == "list" ]]; then
  if [[ "$*" == *"headRefName"* ]]; then
    printf '%s\n' 'open-pr-branch'
    exit 0
  fi

  printf '%s\n' '[{"number":10,"updatedAt":"2026-05-01T12:00:00Z","labels":[]},{"number":11,"updatedAt":"2026-05-01T12:00:00Z","labels":[{"name":"keep"}]}]'
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

extract_close_stale_script() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("close-stale").fetch("steps").fetch(0).fetch("run")' \
    "$repo_root/.github/workflows/close-stale-pull-requests-reusable.yml"
}

extract_clean_branches_script() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("close-stale").fetch("steps").fetch(1).fetch("run")' \
    "$repo_root/.github/workflows/close-stale-pull-requests-reusable.yml"
}

@test "close stale workflow iterates over pull requests returned by gh" {
  script="$tmpdir/close-stale.sh"
  extract_close_stale_script > "$script"

  run env \
    REPO="trade-tariff/example" \
    STALE_DAYS="14" \
    KEEP_LABEL="keep" \
    DRY_RUN="true" \
    bash "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "[DRY RUN] Would close PR #10"
  assert_contains "$output" "Skipping PR #11 (label: keep)"
  assert_contains "$output" "Summary: closed=0, skipped_keep=1, skipped_fresh=0"
}

@test "close stale workflow deletes the branch when closing a pull request" {
  script="$tmpdir/close-stale.sh"
  extract_close_stale_script > "$script"

  run env \
    TEST_CAPTURE_DIR="$tmpdir" \
    REPO="trade-tariff/example" \
    STALE_DAYS="14" \
    KEEP_LABEL="keep" \
    DRY_RUN="false" \
    bash "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "Closed PR #10"
  assert_contains "$output" "Summary: closed=1, skipped_keep=1, skipped_fresh=0"
  close_commands="$(cat "$tmpdir/gh-close-commands.txt")"
  assert_contains "$close_commands" "pr close 10 --repo trade-tariff/example"
  assert_contains "$close_commands" "--delete-branch"
}

@test "clean branches workflow deletes stale branches without open pull requests" {
  script="$tmpdir/clean-branches.sh"
  extract_clean_branches_script > "$script"

  run env \
    TEST_CAPTURE_DIR="$tmpdir" \
    REPO="trade-tariff/example" \
    STALE_DAYS="14" \
    DRY_RUN="false" \
    bash "$script"

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
