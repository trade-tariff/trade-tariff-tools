#!/usr/bin/env bats

load test_helper

setup() {
  repo="$(mktemp -d)"
  script="${BATS_TEST_DIRNAME}/../.github/actions/check-pr-lines/check-pr-lines.sh"
  [[ -f "$script" ]] || fail "missing ${script}"

  git -C "$repo" init -q
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "Test User"

  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm "base"
  base_sha="$(git -C "$repo" rev-parse HEAD)"

  printf 'base\nchanged\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -qm "head"
  head_sha="$(git -C "$repo" rev-parse HEAD)"
}

teardown() {
  rm -rf "$repo"
}

@test "passes when changes are within threshold" {
  cd "$repo" || return 1
  run bash "$script" --threshold 10 --base "$base_sha" --head "$head_sha"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR changes 1 lines"* ]]
}

@test "fails when changes exceed threshold" {
  cd "$repo" || return 1
  run bash "$script" --threshold 0 --base "$base_sha" --head "$head_sha"
  [ "$status" -eq 1 ]
  [[ "$output" == *"exceeds the limit"* ]]
}

@test "excludes paths from the line count" {
  printf 'noise\n' > "$repo/ignored.lock"
  git -C "$repo" add ignored.lock
  git -C "$repo" commit -qm "add lockfile"
  head_with_lock="$(git -C "$repo" rev-parse HEAD)"

  exclude_file="$(mktemp)"
  printf '%s\n' '*.lock' > "$exclude_file"

  cd "$repo" || return 1

  run bash "$script" \
    --threshold 1 \
    --base "$base_sha" \
    --head "$head_with_lock"
  [ "$status" -eq 1 ]

  run bash "$script" \
    --threshold 1 \
    --base "$base_sha" \
    --head "$head_with_lock" \
    --exclude-paths-file "$exclude_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR changes 1 lines"* ]]

  rm -f "$exclude_file"
}

@test "excludes generated and vendored Rails assets by default" {
  mkdir -p "$repo/vendor/javascript" "$repo/app/assets/builds" "$repo/public/assets"
  seq 1 700 > "$repo/vendor/javascript/govuk-frontend.js"
  seq 1 700 > "$repo/app/assets/builds/application.js"
  seq 1 700 > "$repo/public/assets/application-digest.js"
  printf 'app change\n' > "$repo/app.rb"
  git -C "$repo" add app.rb vendor/javascript/govuk-frontend.js app/assets/builds/application.js public/assets/application-digest.js
  git -C "$repo" commit -qm "add generated assets"
  head_with_assets="$(git -C "$repo" rev-parse HEAD)"

  cd "$repo" || return 1

  run bash "$script" \
    --threshold 2 \
    --base "$base_sha" \
    --head "$head_with_assets"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR changes 2 lines"* ]]
}

@test "counts changes from the merge base when the base branch has moved" {
  git -C "$repo" switch -qc pr-branch "$base_sha"
  printf 'branch change\n' > "$repo/feature.txt"
  git -C "$repo" add feature.txt
  git -C "$repo" commit -qm "branch change"
  pr_head_sha="$(git -C "$repo" rev-parse HEAD)"

  git -C "$repo" switch -qc base-branch "$base_sha"
  printf 'unrelated base change\n' > "$repo/unrelated.txt"
  git -C "$repo" add unrelated.txt
  git -C "$repo" commit -qm "unrelated base change"
  moved_base_sha="$(git -C "$repo" rev-parse HEAD)"

  cd "$repo" || return 1

  run bash "$script" \
    --threshold 1 \
    --base "$moved_base_sha" \
    --head "$pr_head_sha"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR changes 1 lines"* ]]
}

@test "counts stacked pull request changes from the merge base of the base ref" {
  git -C "$repo" switch -qc parent-pr "$base_sha"
  printf 'parent change\n' > "$repo/parent.txt"
  git -C "$repo" add parent.txt
  git -C "$repo" commit -qm "parent change"
  parent_original_sha="$(git -C "$repo" rev-parse HEAD)"

  git -C "$repo" switch -qc child-pr "$parent_original_sha"
  printf 'child change\n' > "$repo/child.txt"
  git -C "$repo" add child.txt
  git -C "$repo" commit -qm "child change"
  child_head_sha="$(git -C "$repo" rev-parse HEAD)"

  git -C "$repo" switch parent-pr
  printf 'parent follow-up\n' > "$repo/parent-follow-up.txt"
  git -C "$repo" add parent-follow-up.txt
  git -C "$repo" commit -qm "parent follow-up"

  cd "$repo" || return 1

  run bash "$script" \
    --threshold 1 \
    --base "$base_sha" \
    --base-ref parent-pr \
    --head "$child_head_sha"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PR changes 1 lines"* ]]
}
