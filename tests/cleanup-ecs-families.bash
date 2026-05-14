#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/cleanup-ecs-families"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    fail "expected to find [$needle] in:\n$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "did not expect to find [$needle] in:\n$haystack"
  fi
}

stub_bin="$tmpdir/bin"
mkdir -p "$stub_bin"

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

output="$(PATH="$stub_bin:$PATH" "$script" report)"

assert_not_contains "$output" " - admin-job"
assert_not_contains "$output" " - dev-hub-job"
assert_not_contains "$output" " - backend-job"
assert_contains "$output" " - stale-worker"
assert_contains "$output" " - backend-service"

targeted_output="$(PATH="$stub_bin:$PATH" "$script" report --family admin-job)"

assert_contains "$targeted_output" "No unused families found to process."
assert_not_contains "$targeted_output" " - admin-job"

capture_dir="$tmpdir/capture"
mkdir -p "$capture_dir"
TEST_CAPTURE_DIR="$capture_dir" TEST_FAMILIES="admin admin-job" PATH="$stub_bin:$PATH" "$script" deregister >/dev/null
deregistered="$(cat "$capture_dir/deregistered.txt")"

assert_contains "$deregistered" "task-definition/admin:2"
assert_not_contains "$deregistered" "task-definition/admin-job:7"

echo 'PASS: cleanup-ecs-families'
