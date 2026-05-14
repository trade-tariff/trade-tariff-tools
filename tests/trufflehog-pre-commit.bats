#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "ignored tfstate files are added to TruffleHog excludes" {
  project="$tmpdir/project"
  mkdir -p "$project"
  (
    cd "$project"
    git init -q
    cat > .gitignore <<'GITIGNORE'
*.tfstate
ignored-dir/
GITIGNORE
    touch terraform.tfstate keep.txt
    mkdir -p ignored-dir
    touch ignored-dir/secret.txt
  )

  capture="$tmpdir/capture"
  run run_trufflehog_pre_commit_with_stub_docker "$project" "$capture"

  [ "$status" -eq 0 ]
  exclude_contents="$(cat "$capture/exclude-file.txt")"
  assert_contains "$exclude_contents" '(^|/)\.git(/|$)'
  assert_contains "$exclude_contents" '(^|/)\.terraform(/|$)'
  assert_contains "$exclude_contents" '(^|/)terraform\.tfstate$'
  assert_contains "$exclude_contents" '(^|/)ignored-dir(/|$)'
  assert_not_contains "$exclude_contents" 'keep\.txt'
}

@test "gitignored paths are discovered when scanning through a symlinked path" {
  real_root="$tmpdir/real-root"
  linked_root="$tmpdir/linked-root"
  mkdir -p "$real_root/project"
  ln -s "$real_root" "$linked_root"

  (
    cd "$real_root/project"
    git init -q
    cat > .gitignore <<'GITIGNORE'
*.tfstate
GITIGNORE
    touch terraform.tfstate keep.txt
  )

  capture="$tmpdir/capture"
  run run_trufflehog_pre_commit_with_stub_docker "$linked_root/project" "$capture"

  [ "$status" -eq 0 ]
  exclude_contents="$(cat "$capture/exclude-file.txt")"
  assert_contains "$exclude_contents" '(^|/)terraform\.tfstate$'
  assert_not_contains "$exclude_contents" 'keep\.txt'
}

@test "subdirectory scans only include ignores beneath the scan dir" {
  subproject="$tmpdir/subproject"
  mkdir -p "$subproject/app"
  (
    cd "$subproject"
    git init -q
    cat > .gitignore <<'GITIGNORE'
app/*.tfstate
root-only.tfstate
GITIGNORE
    touch app/terraform.tfstate root-only.tfstate
  )

  capture="$tmpdir/capture"
  run run_trufflehog_pre_commit_with_stub_docker "$subproject/app" "$capture"

  [ "$status" -eq 0 ]
  exclude_subdir="$(cat "$capture/exclude-file.txt")"
  assert_contains "$exclude_subdir" '(^|/)terraform\.tfstate$'
  assert_not_contains "$exclude_subdir" 'root-only\.tfstate'
}

@test "non-git directories still work with default exclusions only" {
  plain_dir="$tmpdir/plain"
  mkdir -p "$plain_dir"

  capture="$tmpdir/capture"
  run run_trufflehog_pre_commit_with_stub_docker "$plain_dir" "$capture"

  [ "$status" -eq 0 ]
  exclude_plain="$(cat "$capture/exclude-file.txt")"
  assert_contains "$exclude_plain" '(^|/)\.git(/|$)'
  assert_not_contains "$exclude_plain" 'terraform\.tfstate'
}
