#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  script="$repo_root/scripts/cleanup-preview-environments.sh"
  output_file="$tmpdir/github-output"

  cat > "$stub_bin/preevy" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "ls" ]]; then
  if [[ -n "${PREEVY_LS_FAIL:-}" ]]; then
    exit 1
  fi
  if [[ -n "${PREEVY_LS_NULL:-}" ]]; then
    printf '%s\n' 'null'
    exit 0
  fi
  printf '%s\n' '[{"envId":"trade-tariff-frontend-feature-a"},{"envId":"trade-tariff-admin-keep-me"},{"envId":"trade-tariff-frontend-labelled"},{"envId":"trade-tariff-admin-broken"},{"envId":"trade-tariff-frontend-no-pr"}]'
  exit 0
fi

if [[ "$1" == "down" ]]; then
  printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/preevy-down.txt"
  if [[ "$*" == *"trade-tariff-admin-broken"* ]]; then
    exit 1
  fi
  exit 0
fi

echo "unexpected preevy command: $*" >&2
exit 1
STUB
  chmod +x "$stub_bin/preevy"

  cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "pr" && "$2" == "list" ]]; then
  if [[ "$*" == *"trade-tariff/trade-tariff-frontend"* ]]; then
    printf '%s\n' '1::Feature-A' '2::labelled'
  else
    printf '%s\n' '3::broken'
  fi
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "view" ]]; then
  if [[ "$3" == "2" ]]; then
    printf '%s\n' 'keep-preview'
  else
    printf '%s\n' 'needs-preview'
  fi
  exit 0
fi

if [[ "$1" == "pr" && "$2" == "edit" ]]; then
  printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/gh-edit-commands.txt"
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

run_cleanup() {
  run env GITHUB_OUTPUT="$output_file" PREEVY_PROFILE_URL="s3://profile" "$@" "$script"
}

@test "destroys unused environments and removes the preview label" {
  run_cleanup DRY_RUN="false" RUN_MODE="scheduled"

  [ "$status" -eq 0 ]
  assert_contains "$output" "🛑 Skipping (excluded by naming): trade-tariff-admin-keep-me"
  assert_contains "$output" "🛑 Skipping: trade-tariff-frontend-labelled (PR #2 in trade-tariff/trade-tariff-frontend is labeled keep-preview)"
  assert_contains "$output" "🔥 Destroying: trade-tariff-frontend-feature-a"
  assert_contains "$output" "❌ Failed to destroy: trade-tariff-admin-broken"

  down_commands="$(cat "$tmpdir/preevy-down.txt")"
  assert_contains "$down_commands" "down --id trade-tariff-frontend-feature-a --force --wait --profile s3://profile"
  assert_contains "$down_commands" "down --id trade-tariff-frontend-no-pr --force --wait --profile s3://profile"
  assert_not_contains "$down_commands" "keep-me"
  assert_not_contains "$down_commands" "labelled"

  # Only PR 1 is edited: "broken" (PR 3) failed to destroy, and "no-pr" has no PR.
  edit_commands="$(cat "$tmpdir/gh-edit-commands.txt")"
  assert_contains "$edit_commands" "pr edit 1 --repo trade-tariff/trade-tariff-frontend --remove-label needs-preview"
  [ "$(wc -l < "$tmpdir/gh-edit-commands.txt")" -eq 1 ]

  outputs="$(cat "$output_file")"
  assert_contains "$outputs" 'destroyed_envs=["trade-tariff-frontend-feature-a","trade-tariff-admin-broken (FAILED)","trade-tariff-frontend-no-pr"]'
  assert_contains "$outputs" "dry_run=false"
  assert_contains "$outputs" "run_mode=scheduled"
}

@test "dry run lists environments without destroying them" {
  run_cleanup DRY_RUN="true" RUN_MODE="manual"

  [ "$status" -eq 0 ]
  assert_contains "$output" "✅ [DRY RUN] Would destroy: trade-tariff-frontend-feature-a"
  [ ! -f "$tmpdir/preevy-down.txt" ]
  [ ! -f "$tmpdir/gh-edit-commands.txt" ]
  outputs="$(cat "$output_file")"
  assert_contains "$outputs" '"trade-tariff-frontend-feature-a (DRY RUN)"'
  assert_contains "$outputs" "dry_run=true"
  assert_contains "$outputs" "run_mode=manual"
}

@test "writes empty outputs when preevy cannot list environments" {
  run_cleanup PREEVY_LS_FAIL=1 DRY_RUN="false" RUN_MODE="scheduled"

  [ "$status" -eq 0 ]
  assert_contains "$output" "⚠️ Failed to list environments"
  outputs="$(cat "$output_file")"
  assert_contains "$outputs" "destroyed_envs=[]"
  assert_contains "$outputs" "dry_run=false"
  assert_contains "$outputs" "run_mode=scheduled"
}

@test "handles a null environment list" {
  run_cleanup PREEVY_LS_NULL=1 DRY_RUN="false" RUN_MODE="scheduled"

  [ "$status" -eq 0 ]
  assert_contains "$output" "⚠️ No environments found"
  assert_contains "$(cat "$output_file")" "destroyed_envs=[]"
}

@test "writes outputs to stdout when GITHUB_OUTPUT is not set" {
  run env -u GITHUB_OUTPUT PREEVY_PROFILE_URL="s3://profile" PREEVY_LS_NULL=1 DRY_RUN="true" RUN_MODE="manual" "$script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "destroyed_envs=[]"
}

@test "requires its environment" {
  run env -u PREEVY_PROFILE_URL DRY_RUN="true" RUN_MODE="manual" "$script"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: PREEVY_PROFILE_URL"
}

@test "prints help" {
  run "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: cleanup-preview-environments.sh"
}

@test "preview cleanup workflow delegates to the script" {
  workflow="$repo_root/.github/workflows/preview-cleanup.yml"

  run grep -F "run: scripts/cleanup-preview-environments.sh" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "DRY_RUN: \${{ github.event_name == 'schedule' && 'false' || github.event.inputs.dry_run || 'true' }}" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F "RUN_MODE: \${{ github.event_name == 'schedule' && 'scheduled' || 'manual' }}" "$workflow"
  [ "$status" -eq 0 ]
  run grep -F 'if [[ "${{ github.event_name }}"' "$workflow"
  [ "$status" -ne 0 ]
}
