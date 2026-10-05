#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path
  mkdir -p "$tmpdir/capture"
  write_stubs
}

teardown() {
  rm -rf "$tmpdir"
}

write_stubs() {
  cat > "$stub_bin/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/aws-calls.txt"

arg_value() {
  local name="$1"
  shift
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "$name" ]]; then
      echo "$2"
      return
    fi
    shift
  done
}

case "$1 $2" in
  "sts get-caller-identity")
    printf '{"Account":"844815912454"}'
    ;;
  "ecs list-services")
    printf '{"serviceArns":["arn:aws:ecs:eu-west-2:844815912454:service/trade-tariff-cluster-development/admin","arn:aws:ecs:eu-west-2:844815912454:service/trade-tariff-cluster-development/identity"]}'
    ;;
  "ecs list-task-definition-families")
    printf '{"families":["admin-844815912454","admin-job-844815912454","backend-job-844815912454","dev-hub-job-844815912454","identity-job-844815912454","stale-job"]}'
    ;;
  "ecs describe-services")
    case "$(arg_value --services "$@")" in
      admin|identity)
        printf '{"services":[{"serviceName":"%s","status":"ACTIVE"}],"failures":[]}' "$(arg_value --services "$@")"
        ;;
      *)
        printf '{"services":[],"failures":[{"reason":"MISSING"}]}'
        ;;
    esac
    ;;
  "ecs describe-task-definition")
    case "$(arg_value --task-definition "$@")" in
      admin-job-844815912454)
        printf '{"taskDefinition":{"taskDefinitionArn":"arn:aws:ecs:eu-west-2:844815912454:task-definition/admin-job-844815912454:7"}}'
        ;;
      *)
        echo "An error occurred (ClientException): Unable to describe task definition." >&2
        exit 254
        ;;
    esac
    ;;
  "ecs list-tasks")
    if [[ -n "$(arg_value --service-name "$@")" ]]; then
      printf '{"taskArns":["arn:aws:ecs:eu-west-2:844815912454:task/trade-tariff-cluster-development/task-svc-1"]}'
    else
      printf '%s\n' "$*" > "$TEST_CAPTURE_DIR/list-job-tasks-args.txt"
      jq -cn --arg tasks "${TEST_JOB_TASKS:-}" \
        '{taskArns: ($tasks | split(" ") | map(select(. != "")) | map("arn:aws:ecs:eu-west-2:844815912454:task/trade-tariff-cluster-development/" + .))}'
    fi
    ;;
  "ecs describe-tasks")
    # Emit one task per requested ID. Scheduled runs have ECS Exec disabled.
    # Every task has a stopped init container first, like a read-only task.
    tasks=()
    collecting=false
    for arg in "$@"; do
      if [[ "$arg" == "--tasks" ]]; then
        collecting=true
        continue
      fi
      if [[ "$collecting" == true ]]; then
        [[ "$arg" == --* ]] && break
        tasks+=("${arg##*/}")
      fi
    done
    printf '%s\n' "${tasks[@]}" | jq -R . | jq -cs '{tasks: map({
      taskArn: ("arn:aws:ecs:eu-west-2:844815912454:task/trade-tariff-cluster-development/" + .),
      lastStatus: "RUNNING",
      enableExecuteCommand: (test("scheduled") | not),
      containers: [
        {name: "admin-job-volume-permissions", managedAgents: [{lastStatus: "STOPPED"}]},
        {name: "admin-job", managedAgents: [{lastStatus: "RUNNING"}]},
        {name: "admin", managedAgents: [{lastStatus: "RUNNING"}]}
      ]
    })}'
    ;;
  "ec2 describe-subnets")
    printf 'subnet-1\tsubnet-2'
    ;;
  "ec2 describe-security-groups")
    printf 'sg-123'
    ;;
  "ecs run-task")
    printf '%s\n' "$*" > "$TEST_CAPTURE_DIR/run-task-args.txt"
    printf '{"tasks":[{"taskArn":"arn:aws:ecs:eu-west-2:844815912454:task/trade-tariff-cluster-development/task-new"}],"failures":[]}'
    ;;
  "ecs stop-task")
    printf '%s\n' "$*" > "$TEST_CAPTURE_DIR/stop-task-args.txt"
    printf '{}'
    ;;
  "ecs execute-command")
    printf '%s\n' "$*" > "$TEST_CAPTURE_DIR/execute-command-args.txt"
    ;;
  *)
    echo "unexpected aws command: $*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub_bin/aws"

  cat > "$stub_bin/fzf" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
case "$*" in
  *"Select a Cluster"*)
    echo "trade-tariff-cluster-development"
    ;;
  *"Select a Service"*)
    printf '%s\n' "$input" > "$TEST_CAPTURE_DIR/service-choices.txt"
    echo "$TEST_SELECT_SERVICE"
    ;;
  *"Select a Task"*)
    printf '%s\n' "$input" > "$TEST_CAPTURE_DIR/task-choices.txt"
    printf '%s\n' "$input" | head -n 1
    ;;
  *)
    echo "unexpected fzf prompt: $*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub_bin/fzf"
}

run_ecs() {
  run env TEST_CAPTURE_DIR="$tmpdir/capture" "$@" "$repo_root/bin/ecs"
}

@test "ecs lists every job task family next to the ECS services" {
  run_ecs TEST_SELECT_SERVICE=admin

  [ "$status" -eq 0 ]
  choices="$(cat "$tmpdir/capture/service-choices.txt")"
  for name in admin identity admin-job backend-job dev-hub-job identity-job; do
    assert_contains "$choices" "$name"
  done
  assert_not_contains "$choices" "stale-job"
  assert_not_contains "$choices" "844815912454"
}

@test "ecs starts an exec-enabled task for a job with no running tasks and stops it on exit" {
  run_ecs TEST_SELECT_SERVICE=admin-job

  [ "$status" -eq 0 ]
  assert_contains "$output" "Started task: task-new"
  assert_contains "$output" "Stopping job task task-new"

  assert_contains "$(cat "$tmpdir/capture/list-job-tasks-args.txt")" "--family admin-job-844815912454"

  run_task_args="$(cat "$tmpdir/capture/run-task-args.txt")"
  assert_contains "$run_task_args" "--task-definition arn:aws:ecs:eu-west-2:844815912454:task-definition/admin-job-844815912454:7"
  assert_contains "$run_task_args" "--enable-execute-command"
  assert_contains "$run_task_args" "--started-by ecs-exec-script"
  assert_contains "$run_task_args" "awsvpcConfiguration={subnets=[subnet-1,subnet-2],securityGroups=[sg-123],assignPublicIp=DISABLED}"

  exec_args="$(cat "$tmpdir/capture/execute-command-args.txt")"
  assert_contains "$exec_args" "--task task-new"
  assert_contains "$exec_args" "--container admin-job"

  assert_contains "$(cat "$tmpdir/capture/stop-task-args.txt")" "--task task-new"
}

@test "ecs waits for the exec agent on the job container, not the init container" {
  run_ecs TEST_SELECT_SERVICE=admin-job

  [ "$status" -eq 0 ]
  assert_contains "$output" "Task status: AGENT RUNNING"
}

@test "ecs reuses a running exec-enabled job task and skips scheduled runs" {
  run_ecs TEST_SELECT_SERVICE=admin-job TEST_JOB_TASKS="task-scheduled task-existing-exec"

  [ "$status" -eq 0 ]
  assert_contains "$output" "admin-job-844815912454 has 1 running task(s) with ECS Exec enabled"

  task_choices="$(cat "$tmpdir/capture/task-choices.txt")"
  assert_contains "$task_choices" "task-existing-exec"
  assert_not_contains "$task_choices" "task-scheduled"

  assert_contains "$(cat "$tmpdir/capture/execute-command-args.txt")" "--task task-existing-exec"
  [ ! -f "$tmpdir/capture/run-task-args.txt" ]
  [ ! -f "$tmpdir/capture/stop-task-args.txt" ]
}

@test "ecs starts a new job task when only scheduled runs are running" {
  run_ecs TEST_SELECT_SERVICE=admin-job TEST_JOB_TASKS="task-scheduled"

  [ "$status" -eq 0 ]
  assert_contains "$output" "Started task: task-new"
  assert_contains "$(cat "$tmpdir/capture/execute-command-args.txt")" "--task task-new"
}

@test "ecs still selects service tasks by service name" {
  run_ecs TEST_SELECT_SERVICE=admin

  [ "$status" -eq 0 ]
  aws_calls="$(cat "$tmpdir/capture/aws-calls.txt")"
  assert_contains "$aws_calls" "ecs list-tasks --cluster trade-tariff-cluster-development --service-name admin"
  assert_not_contains "$aws_calls" "ecs run-task"

  exec_args="$(cat "$tmpdir/capture/execute-command-args.txt")"
  assert_contains "$exec_args" "--task task-svc-1"
  assert_contains "$exec_args" "--container admin"
}

@test "ecs reports a missing job task definition" {
  run_ecs TEST_SELECT_SERVICE=missing-job

  [ "$status" -ne 0 ]
  assert_contains "$output" "Could not find an active task definition for family 'missing-job-844815912454'"
  [ ! -f "$tmpdir/capture/run-task-args.txt" ]
}
