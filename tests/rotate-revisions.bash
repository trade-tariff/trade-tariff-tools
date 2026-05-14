#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/bin/rotate-revisions"

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

capture_prefix="$tmpdir/capture-prefix"
mkdir -p "$capture_prefix"
TEST_CAPTURE_DIR="$capture_prefix" TEST_FAMILIES="admin" PATH="$stub_bin:$PATH" "$script" 0 >/dev/null
deregistered_prefix="$(cat "$capture_prefix/deregistered.txt")"

assert_contains "$deregistered_prefix" "task-definition/admin:2"
assert_not_contains "$deregistered_prefix" "task-definition/admin-job:7"

capture_job="$tmpdir/capture-job"
mkdir -p "$capture_job"
TEST_CAPTURE_DIR="$capture_job" TEST_FAMILIES="admin-job" PATH="$stub_bin:$PATH" "$script" 0 >/dev/null
deregistered_job="$(cat "$capture_job/deregistered.txt")"

assert_contains "$deregistered_job" "task-definition/admin-job:7"

echo 'PASS: rotate-revisions'
