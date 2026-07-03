#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
}

teardown() {
  rm -rf "$tmpdir"
}

write_common_stubs() {
  local fzf_mode="${1:-fail-if-called}"

  cat > "$stub_bin/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/aws-calls.txt"

case "$1 $2" in
  "sts get-caller-identity")
    printf '{"Account":"451934005581"}'
    ;;
  "events list-rules")
    if [[ "${TEST_INCLUDE_PRODUCTION_ONLY:-}" == "true" ]]; then
      printf '{"Rules":[{"Name":"backend-database-replication-production"}]}'
    elif [[ "${TEST_INCLUDE_DEVELOPMENT_REPLICATION:-}" == "true" ]]; then
      printf '{"Rules":[{"Name":"backend-database-replication-development"},{"Name":"backend-database-replication-staging"},{"Name":"backend-database-backup-staging"}]}'
    else
      printf '{"Rules":[{"Name":"backend-database-replication-staging"},{"Name":"backend-database-backup-staging"}]}'
    fi
    ;;
  "events list-targets-by-rule")
    rule=""
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "--rule" ]]; then
        rule="$2"
        break
      fi
      shift
    done

    case "$rule" in
      "backend-database-replication-staging")
        if [[ "${TEST_MULTIPLE_STAGING_TARGETS:-}" == "true" ]]; then
          cat <<'JSON'
{"Targets":[{"Id":"target-a","Arn":"arn:aws:ecs:eu-west-2:451934005581:cluster/trade-tariff-cluster-staging","Input":"{\"containerOverrides\":[{\"name\":\"backend-job\",\"command\":[\"/bin/sh\",\"-c\",\"./bin/db-replicate\"]}]}","EcsParameters":{"TaskDefinitionArn":"arn:aws:ecs:eu-west-2:451934005581:task-definition/backend-job-451934005581:1019"}},{"Id":"target-b","Arn":"arn:aws:ecs:eu-west-2:451934005581:cluster/trade-tariff-cluster-staging","Input":"{\"containerOverrides\":[{\"name\":\"backend-job\",\"command\":[\"/bin/sh\",\"-c\",\"./bin/other\"]}]}","EcsParameters":{"TaskDefinitionArn":"arn:aws:ecs:eu-west-2:451934005581:task-definition/backend-job-451934005581:1019"}}]}
JSON
        else
        cat <<'JSON'
{"Targets":[{"Arn":"arn:aws:ecs:eu-west-2:451934005581:cluster/trade-tariff-cluster-staging","Input":"{\"containerOverrides\":[{\"name\":\"backend-job\",\"command\":[\"/bin/sh\",\"-c\",\"./bin/db-replicate\"]}]}","EcsParameters":{"TaskDefinitionArn":"arn:aws:ecs:eu-west-2:451934005581:task-definition/backend-job-451934005581:1019"}}]}
JSON
        fi
        ;;
      "backend-database-backup-staging")
        cat <<'JSON'
{"Targets":[{"Arn":"arn:aws:ecs:eu-west-2:451934005581:cluster/trade-tariff-cluster-staging","Input":"{\"containerOverrides\":[{\"name\":\"backend-job\",\"command\":[\"/bin/sh\",\"-c\",\"./bin/backup-database\"]}]}","EcsParameters":{"TaskDefinitionArn":"arn:aws:ecs:eu-west-2:451934005581:task-definition/backend-job-451934005581:1020"}}]}
JSON
        ;;
      "backend-database-replication-development")
        cat <<'JSON'
{"Targets":[{"Arn":"arn:aws:ecs:eu-west-2:844815912454:cluster/trade-tariff-cluster-development","Input":"{\"containerOverrides\":[{\"name\":\"backend-job\",\"command\":[\"/bin/sh\",\"-c\",\"./bin/db-replicate\"]}]}","EcsParameters":{"TaskDefinitionArn":"arn:aws:ecs:eu-west-2:844815912454:task-definition/backend-job-844815912454:300"}}]}
JSON
        ;;
      "backend-database-replication-production")
        cat <<'JSON'
{"Targets":[{"Arn":"arn:aws:ecs:eu-west-2:382373577178:cluster/trade-tariff-cluster-production","Input":"{\"containerOverrides\":[{\"name\":\"backend-job\",\"command\":[\"/bin/sh\",\"-c\",\"./bin/db-replicate\"]}]}","EcsParameters":{"TaskDefinitionArn":"arn:aws:ecs:eu-west-2:382373577178:task-definition/backend-job-382373577178:900"}}]}
JSON
        ;;
      *)
        printf '{"Targets":[]}'
        ;;
    esac
    ;;
  "ec2 describe-subnets")
    printf 'subnet-1\tsubnet-2'
    ;;
  "ec2 describe-security-groups")
    printf 'sg-123'
    ;;
  "ecs describe-task-definition")
    task_definition=""
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "--task-definition" ]]; then
        task_definition="$2"
        break
      fi
      shift
    done

    case "$task_definition" in
      "backend-job-451934005581")
        printf '{"taskDefinition":{"taskDefinitionArn":"arn:aws:ecs:eu-west-2:451934005581:task-definition/backend-job-451934005581:1020"}}'
        ;;
      "backend-job-844815912454")
        printf '{"taskDefinition":{"taskDefinitionArn":"arn:aws:ecs:eu-west-2:844815912454:task-definition/backend-job-844815912454:301"}}'
        ;;
      "backend-job-382373577178")
        printf '{"taskDefinition":{"taskDefinitionArn":"arn:aws:ecs:eu-west-2:382373577178:task-definition/backend-job-382373577178:901"}}'
        ;;
      *)
        echo "unexpected task definition family: $task_definition" >&2
        exit 1
        ;;
    esac
    ;;
  "ecs run-task")
    printf '%s\n' "$*" > "$TEST_CAPTURE_DIR/run-task-args.txt"
    if [[ "${TEST_RUN_TASK_FAILURE:-}" == "true" ]]; then
      printf '{"tasks":[],"failures":[{"arn":"arn:aws:ecs:eu-west-2:451934005581:task-definition/backend-job-451934005581:1020","reason":"CLIENT_EXCEPTION","detail":"TaskDefinition is inactive"}]}'
    elif [[ "${TEST_RUN_TASK_NULL_ARN:-}" == "true" ]]; then
      printf '{"tasks":[{"taskArn":null}],"failures":[]}'
    else
      printf '{"tasks":[{"taskArn":"arn:aws:ecs:eu-west-2:451934005581:task/trade-tariff-cluster-staging/task-123"}],"failures":[]}'
    fi
    ;;
  "ecs describe-tasks")
    exit_code="${TEST_TASK_EXIT_CODE:-0}"
    printf '{"tasks":[{"lastStatus":"STOPPED","stoppedReason":"Essential container in task exited","containers":[{"name":"backend-job","exitCode":%s,"reason":"test reason"}]}]}' "$exit_code"
    ;;
  "logs tail")
    printf '%s\n' "$*" > "$TEST_CAPTURE_DIR/logs-tail-args.txt"
    ;;
  *)
    echo "unexpected aws command: $*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub_bin/aws"

  case "$fzf_mode" in
    none)
      ;;
    select-job)
      cat > "$stub_bin/fzf" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
awk -F '\t' '$1 == "backend-database-replication" { print; exit }'
STUB
      chmod +x "$stub_bin/fzf"
      ;;
    fail-if-called)
      cat > "$stub_bin/fzf" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "fzf should not be called for non-interactive ecs run" >&2
exit 1
STUB
      chmod +x "$stub_bin/fzf"
      ;;
  esac
}

@test "ecs run detects scheduled jobs without selecting an ECS cluster first" {
  write_common_stubs select-job
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" "$repo_root/bin/ecs" \
    run \
    --yes \
    --no-tail

  [ "$status" -eq 0 ]
  assert_contains "$output" "Started task: task-123"

  aws_calls="$(cat "$tmpdir/capture/aws-calls.txt")"
  assert_not_contains "$aws_calls" "ecs list-clusters"
  assert_contains "$(cat "$tmpdir/capture/run-task-args.txt")" "--cluster trade-tariff-cluster-staging"
}

@test "ecs run starts named scheduled job without interactive selection" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" "$repo_root/bin/ecs" \
    run \
    --environment staging \
    --yes \
    --no-tail \
    backend-database-replication

  [ "$status" -eq 0 ]
  assert_contains "$output" "Started task: task-123"

  run_task_args="$(cat "$tmpdir/capture/run-task-args.txt")"
  assert_contains "$run_task_args" "--cluster trade-tariff-cluster-staging"
  assert_contains "$run_task_args" "--task-definition arn:aws:ecs:eu-west-2:451934005581:task-definition/backend-job-451934005581:1020"
  assert_contains "$run_task_args" "awsvpcConfiguration={subnets=[subnet-1,subnet-2],securityGroups=[sg-123],assignPublicIp=DISABLED}"
  assert_contains "$run_task_args" "--overrides {\"containerOverrides\":[{\"name\":\"backend-job\",\"command\":[\"/bin/sh\",\"-c\",\"./bin/db-replicate\"]}]}"
}

@test "ecs run detects environment for unique named scheduled job" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" "$repo_root/bin/ecs" \
    run \
    --yes \
    --no-tail \
    backend-database-replication

  [ "$status" -eq 0 ]
  assert_contains "$output" "Started task: task-123"

  run_task_args="$(cat "$tmpdir/capture/run-task-args.txt")"
  assert_contains "$run_task_args" "--cluster trade-tariff-cluster-staging"
  assert_contains "$run_task_args" "--task-definition arn:aws:ecs:eu-west-2:451934005581:task-definition/backend-job-451934005581:1020"
  assert_not_contains "$(cat "$tmpdir/capture/aws-calls.txt")" "ecs list-clusters"
}

@test "ecs run reports available jobs when named job is unknown" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" "$repo_root/bin/ecs" \
    run \
    --environment staging \
    --yes \
    --no-tail \
    missing-job

  [ "$status" -ne 0 ]
  assert_contains "$output" "No ECS job named 'missing-job' found in staging"
  assert_contains "$output" "backend-database-replication"
  assert_contains "$output" "backend-database-backup"
}

@test "ecs run requires environment when named scheduled job is ambiguous" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" TEST_INCLUDE_DEVELOPMENT_REPLICATION=true "$repo_root/bin/ecs" \
    run \
    --yes \
    --no-tail \
    backend-database-replication

  [ "$status" -ne 0 ]
  assert_contains "$output" "Multiple ECS jobs named 'backend-database-replication' found"
  assert_contains "$output" "backend-database-replication (development)"
  assert_contains "$output" "backend-database-replication (staging)"
  assert_contains "$output" "Specify --environment to choose one"
}

@test "ecs run detects production jobs from the current AWS account" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" TEST_INCLUDE_PRODUCTION_ONLY=true "$repo_root/bin/ecs" \
    run \
    --yes \
    --no-tail \
    backend-database-replication

  [ "$status" -eq 0 ]
  assert_contains "$(cat "$tmpdir/capture/run-task-args.txt")" "--cluster trade-tariff-cluster-production"
  assert_contains "$(cat "$tmpdir/capture/run-task-args.txt")" "--task-definition arn:aws:ecs:eu-west-2:382373577178:task-definition/backend-job-382373577178:901"
}

@test "ecs run allows production when environment is explicit" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" TEST_INCLUDE_PRODUCTION_ONLY=true "$repo_root/bin/ecs" \
    run \
    --environment production \
    --yes \
    --no-tail \
    backend-database-replication

  [ "$status" -eq 0 ]

  run_task_args="$(cat "$tmpdir/capture/run-task-args.txt")"
  assert_contains "$run_task_args" "--cluster trade-tariff-cluster-production"
  assert_contains "$run_task_args" "--task-definition arn:aws:ecs:eu-west-2:382373577178:task-definition/backend-job-382373577178:901"
}

@test "ecs run reports AWS run-task failures and exits non-zero" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" TEST_RUN_TASK_FAILURE=true "$repo_root/bin/ecs" \
    run \
    --environment staging \
    --yes \
    --no-tail \
    backend-database-replication

  [ "$status" -ne 0 ]
  assert_contains "$output" "Failed to start task"
  assert_contains "$output" "CLIENT_EXCEPTION"
  assert_contains "$output" "TaskDefinition is inactive"
  assert_not_contains "$output" "Started task: null"
}

@test "ecs run fails when AWS run-task response has no task ARN" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" TEST_RUN_TASK_NULL_ARN=true "$repo_root/bin/ecs" \
    run \
    --environment staging \
    --yes \
    --no-tail \
    backend-database-replication

  [ "$status" -ne 0 ]
  assert_contains "$output" "AWS response did not include a task ARN"
  assert_not_contains "$output" "Started task: null"
}

@test "ecs run uses requested region for direct named jobs" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" "$repo_root/bin/ecs" \
    run \
    --region eu-west-1 \
    --environment staging \
    --yes \
    --no-tail \
    backend-database-replication

  [ "$status" -eq 0 ]
  assert_not_contains "$(cat "$tmpdir/capture/aws-calls.txt")" "--region eu-west-2"
  assert_contains "$(cat "$tmpdir/capture/aws-calls.txt")" "--region eu-west-1"
}

@test "ecs run direct named jobs do not require fzf" {
  write_common_stubs none
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" "$repo_root/bin/ecs" \
    run \
    --environment staging \
    --yes \
    --no-tail \
    backend-database-replication

  [ "$status" -eq 0 ]
  assert_contains "$output" "Started task: task-123"
}

@test "ecs run rejects multiple ECS targets for a scheduled rule" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env TEST_CAPTURE_DIR="$tmpdir/capture" TEST_MULTIPLE_STAGING_TARGETS=true "$repo_root/bin/ecs" \
    run \
    --environment staging \
    --yes \
    --no-tail \
    backend-database-replication

  [ "$status" -ne 0 ]
  assert_contains "$output" "Expected exactly one ECS target"
  assert_contains "$output" "target-a"
  assert_contains "$output" "target-b"
}

@test "ecs run exits non-zero when the ECS task fails" {
  write_common_stubs
  mkdir -p "$tmpdir/capture"

  run env \
    TEST_CAPTURE_DIR="$tmpdir/capture" \
    TEST_TASK_EXIT_CODE=23 \
    TASK_POLL_SECONDS=0 \
    FINAL_LOG_FLUSH_SECONDS=0 \
    "$repo_root/bin/ecs" \
    run \
    --environment staging \
    --yes \
    backend-database-replication

  [ "$status" -eq 23 ]
  assert_contains "$output" "Task failed (exit code: 23)"
  assert_contains "$output" "Stopped reason: Essential container in task exited"
  assert_contains "$output" "Container reason: test reason"
}
