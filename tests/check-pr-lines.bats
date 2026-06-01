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
