#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path

  cat > "$stub_bin/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" != "ecs" ]]; then
  echo "unexpected aws service: $1" >&2
  exit 1
fi

shift

case "$1" in
  list-clusters)
    printf '\n'
    ;;
  list-task-definition-families)
    printf '%s\n' "$TEST_FAMILIES"
    ;;
  list-task-definitions)
    family_prefix=""
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "--family-prefix" ]]; then
        family_prefix="$2"
        break
      fi
      shift
    done

    case "$family_prefix" in
      admin)
        printf '%s\n' "arn:aws:ecs:eu-west-2:123456789012:task-definition/admin:2 arn:aws:ecs:eu-west-2:123456789012:task-definition/admin-job:7"
        ;;
      admin-job)
        printf '%s\n' "arn:aws:ecs:eu-west-2:123456789012:task-definition/admin-job:7"
        ;;
      frontend)
        printf '%s\n' "arn:aws:ecs:eu-west-2:123456789012:task-definition/frontend:1049 arn:aws:ecs:eu-west-2:123456789012:task-definition/frontend:1050 arn:aws:ecs:eu-west-2:123456789012:task-definition/frontend:1051 arn:aws:ecs:eu-west-2:123456789012:task-definition/frontend:1052 arn:aws:ecs:eu-west-2:123456789012:task-definition/frontend:1061 arn:aws:ecs:eu-west-2:123456789012:task-definition/frontend:1062 arn:aws:ecs:eu-west-2:123456789012:task-definition/frontend:1063 arn:aws:ecs:eu-west-2:123456789012:task-definition/frontend:1064"
        ;;
      *)
        printf '\n'
        ;;
    esac
    ;;
  deregister-task-definition)
    task_definition=""
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "--task-definition" ]]; then
        task_definition="$2"
        break
      fi
      shift
    done
    printf '%s\n' "$task_definition" >> "$TEST_CAPTURE_DIR/deregistered.txt"
    ;;
  *)
    echo "unexpected ecs command: $1" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub_bin/aws"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "rotating a family ignores prefix results from other families" {
  capture="$tmpdir/capture-prefix"
  mkdir -p "$capture"

  run env TEST_CAPTURE_DIR="$capture" TEST_FAMILIES="admin" "$repo_root/bin/rotate-task-definitions" 0

  [ "$status" -eq 0 ]
  deregistered="$(cat "$capture/deregistered.txt")"
  assert_contains "$deregistered" "task-definition/admin:2"
  assert_not_contains "$deregistered" "task-definition/admin-job:7"
}

@test "rotating a job family still processes the exact job family" {
  capture="$tmpdir/capture-job"
  mkdir -p "$capture"

  run env TEST_CAPTURE_DIR="$capture" TEST_FAMILIES="admin-job" "$repo_root/bin/rotate-task-definitions" 0

  [ "$status" -eq 0 ]
  deregistered="$(cat "$capture/deregistered.txt")"
  assert_contains "$deregistered" "task-definition/admin-job:7"
}

@test "rotating a family keeps the numerically newest revisions when AWS returns older revisions first" {
  capture="$tmpdir/capture-ordering"
  mkdir -p "$capture"

  run env TEST_CAPTURE_DIR="$capture" TEST_FAMILIES="frontend" "$repo_root/bin/rotate-task-definitions" 4

  [ "$status" -eq 0 ]
  deregistered="$(cat "$capture/deregistered.txt")"
  assert_contains "$deregistered" "task-definition/frontend:1049"
  assert_contains "$deregistered" "task-definition/frontend:1050"
  assert_contains "$deregistered" "task-definition/frontend:1051"
  assert_contains "$deregistered" "task-definition/frontend:1052"
  assert_not_contains "$deregistered" "task-definition/frontend:1061"
  assert_not_contains "$deregistered" "task-definition/frontend:1062"
  assert_not_contains "$deregistered" "task-definition/frontend:1063"
  assert_not_contains "$deregistered" "task-definition/frontend:1064"
}
