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
  list-services)
    printf '[]\n'
    ;;
  list-tasks)
    printf '[]\n'
    ;;
  list-task-definition-families)
    printf '%s\n' "${TEST_FAMILIES:-admin-job dev-hub-job backend-job stale-worker backend-service}"
    ;;
  list-task-definitions)
    printf '%s\n' "arn:aws:ecs:eu-west-2:123456789012:task-definition/admin:2 arn:aws:ecs:eu-west-2:123456789012:task-definition/admin-job:7"
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

@test "report preserves task families ending in -job" {
  run "$repo_root/bin/cleanup-ecs-families" report

  [ "$status" -eq 0 ]
  assert_not_contains "$output" " - admin-job"
  assert_not_contains "$output" " - dev-hub-job"
  assert_not_contains "$output" " - backend-job"
  assert_contains "$output" " - stale-worker"
  assert_contains "$output" " - backend-service"
}

@test "targeting a preserved job family finds no cleanup candidates" {
  run "$repo_root/bin/cleanup-ecs-families" report --family admin-job

  [ "$status" -eq 0 ]
  assert_contains "$output" "No unused families found to process."
  assert_not_contains "$output" " - admin-job"
}

@test "deregister ignores prefix results from other families" {
  capture_dir="$tmpdir/capture"
  mkdir -p "$capture_dir"

  run env TEST_CAPTURE_DIR="$capture_dir" TEST_FAMILIES="admin admin-job" "$repo_root/bin/cleanup-ecs-families" deregister

  [ "$status" -eq 0 ]
  deregistered="$(cat "$capture_dir/deregistered.txt")"
  assert_contains "$deregistered" "task-definition/admin:2"
  assert_not_contains "$deregistered" "task-definition/admin-job:7"
}
