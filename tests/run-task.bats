#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
}

teardown() {
  rm -rf "$tmpdir"
}

@test "run-task uses an explicit task definition ARN when supplied" {
  capture="$tmpdir/capture"
  mkdir -p "$capture"

  cat > "$stub_bin/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/aws-calls.txt"

case "$1 $2" in
  "ec2 describe-subnets")
    printf 'subnet-1,subnet-2'
    ;;
  "ec2 describe-security-groups")
    printf 'sg-123'
    ;;
  "ecs run-task")
    task_definition=""
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "--task-definition" ]]; then
        task_definition="$2"
        break
      fi
      shift
    done
    printf '%s\n' "$task_definition" > "$TEST_CAPTURE_DIR/run-task-definition.txt"
    printf 'arn:aws:ecs:eu-west-2:123456789012:task/trade-tariff-cluster-development/task-123'
    ;;
  "ecs wait")
    ;;
  "logs describe-log-streams")
    printf '{"logStreams":[{"creationTime":1,"logStreamName":"ecs/dev-hub-job/task-123"}]}'
    ;;
  "logs get-log-events")
    printf '["migration ok"]'
    ;;
  "ecs describe-tasks")
    printf '0'
    ;;
  "ecs list-task-definitions")
    echo "run-task should not list task definitions when an explicit ARN is supplied" >&2
    exit 1
    ;;
  *)
    echo "unexpected aws command: $*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub_bin/aws"

  explicit_arn="arn:aws:ecs:eu-west-2:123456789012:task-definition/dev-hub-job-123456789012:252"

  run env AWS_REGION=eu-west-2 TEST_CAPTURE_DIR="$capture" "$repo_root/bin/run-task" \
    -e development \
    -t dev-hub-job \
    -d "$explicit_arn" \
    -o '{"containerOverrides":[{"name":"dev-hub-job"}]}'

  [ "$status" -eq 0 ]
  [ "$(cat "$capture/run-task-definition.txt")" = "$explicit_arn" ]
  assert_not_contains "$(cat "$capture/aws-calls.txt")" "ecs list-task-definitions"
}
