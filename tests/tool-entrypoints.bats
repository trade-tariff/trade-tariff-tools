#!/usr/bin/env bats

load test_helper

expected_bash_topmatter() {
  cat <<'TOPMATTER'
#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber
TOPMATTER
}

@test "public bin entrypoints use the standard bash topmatter" {
  while IFS= read -r entrypoint; do
    [ -f "$entrypoint" ] || continue
    actual="$(sed -n '1,7p' "$entrypoint")"
    [ "$actual" = "$(expected_bash_topmatter)" ] || fail "$entrypoint does not use the standard bash topmatter"
  done < <(find "$repo_root/bin" -maxdepth 1 -type f | sort)
}

@test "executable shell scripts use the standard bash topmatter" {
  while IFS= read -r script; do
    actual="$(sed -n '1,7p' "$script")"
    [ "$actual" = "$(expected_bash_topmatter)" ] || fail "$script does not use the standard bash topmatter"
  done < <(find "$repo_root/scripts" -type f -perm -111 -name '*.sh' ! -path "$repo_root/scripts/lib/*" | sort)
}

@test "public bin entrypoint names are hyphenated without implementation extensions" {
  while IFS= read -r entrypoint; do
    name="$(basename "$entrypoint")"
    [[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail "$name is not a standard hyphenated command name"
  done < <(find "$repo_root/bin" -maxdepth 1 -type f | sort)
}

@test "private shell libraries live under scripts/lib" {
  [ -f "$repo_root/scripts/lib/ecs-task-definitions.sh" ]
  [ ! -f "$repo_root/scripts/ecs-task-definition-inventory.sh" ]
}

@test "workflows use the canonical task definition rotation command" {
  workflow="$repo_root/.github/workflows/rotate-task-definitions.yml"

  run grep -F "./bin/rotate-task-definitions" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "./bin/rotate-revisions" "$workflow"
  [ "$status" -ne 0 ]
}
