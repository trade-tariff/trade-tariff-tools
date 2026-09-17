#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path

  mkdir -p "$tmpdir/project/terraform"
  touch "$tmpdir/project/terraform/config_development.tfvars"

  cat > "$stub_bin/terraform" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/terraform-calls.txt"

case "$1" in
  apply)
    exit 0
    ;;
  state)
    cat <<'STATE'
# module.backend-job.aws_ecs_task_definition.this:
arn = "arn:aws:ecs:eu-west-2:123456789012:task-definition/backend-job-123456789012:42"
STATE
    ;;
  *)
    echo "unexpected terraform command: $*" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub_bin/terraform"

  run_task_stub="$tmpdir/run-task"
  cat > "$run_task_stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/run-task-calls.txt"
STUB
  chmod +x "$run_task_stub"
}

teardown() {
  rm -rf "$tmpdir"
}

run_db_migrate() {
  (
    cd "$tmpdir/project"
    TEST_CAPTURE_DIR="$tmpdir" DB_MIGRATE_RUN_TASK="$run_task_stub" "$repo_root/bin/db-migrate" "$@"
  )
}

@test "db-migrate runs one migration task for non-backend apps" {
  run run_db_migrate \
    --app-name tariff-admin \
    --environment development \
    --ref abc123

  [ "$status" -eq 0 ]
  terraform_calls="$(cat "$tmpdir/terraform-calls.txt")"
  run_task_calls="$(cat "$tmpdir/run-task-calls.txt")"

  assert_contains "$terraform_calls" "apply -var-file=config_development.tfvars -auto-approve -lock-timeout=10m -target=module.admin-job"
  assert_contains "$terraform_calls" "state show module.admin-job.aws_ecs_task_definition.this"
  assert_contains "$run_task_calls" "-e development -t admin-job -d arn:aws:ecs:eu-west-2:123456789012:task-definition/backend-job-123456789012:42"
  assert_contains "$run_task_calls" "\"command\":[\"/bin/sh\",\"-c\",\"bundle exec rails db:migrate\"]"
}

@test "db-migrate runs UK and XI migration tasks for backend" {
  run run_db_migrate \
    --app-name tariff-backend \
    --environment development \
    --ref abc123

  [ "$status" -eq 0 ]
  run_task_calls="$(cat "$tmpdir/run-task-calls.txt")"

  call_count="$(wc -l < "$tmpdir/run-task-calls.txt" | tr -d ' ')"
  [ "$call_count" -eq 2 ]
  assert_contains "$run_task_calls" "\"environment\":[{\"name\":\"SERVICE\",\"value\":\"uk\"}]"
  assert_contains "$run_task_calls" "\"environment\":[{\"name\":\"SERVICE\",\"value\":\"xi\"}]"
  assert_contains "$run_task_calls" "bundle exec rails db:migrate && bundle exec rails data:migrate"
}

@test "db-migrate runs the UK and XI migration tasks in parallel" {
  # Replace the stub with one that simulates task duration and records
  # start and end times per schema. Sequential execution cannot produce
  # overlapping intervals.
  cat > "$run_task_stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/run-task-calls.txt"
service="unknown"
case "$*" in
  *'"value":"uk"'*) service="uk" ;;
  *'"value":"xi"'*) service="xi" ;;
esac
start="$(date +%s%3N)"
printf '%s %s %s\n' start "$service" "$start" >> "$TEST_CAPTURE_DIR/task-timing.txt"
sleep 0.3
end="$(date +%s%3N)"
printf '%s %s %s\n' end "$service" "$end" >> "$TEST_CAPTURE_DIR/task-timing.txt"
STUB
  chmod +x "$run_task_stub"

  run run_db_migrate \
    --app-name tariff-backend \
    --environment development \
    --ref abc123

  [ "$status" -eq 0 ]
  start_uk="$(awk '$1 == "start" && $2 == "uk" {print $3}' "$tmpdir/task-timing.txt")"
  end_uk="$(awk '$1 == "end" && $2 == "uk" {print $3}' "$tmpdir/task-timing.txt")"
  start_xi="$(awk '$1 == "start" && $2 == "xi" {print $3}' "$tmpdir/task-timing.txt")"
  end_xi="$(awk '$1 == "end" && $2 == "xi" {print $3}' "$tmpdir/task-timing.txt")"
  [[ -n "$start_uk" && -n "$end_uk" && -n "$start_xi" && -n "$end_xi" ]]
  [ "$start_uk" -lt "$end_xi" ]
  [ "$start_xi" -lt "$end_uk" ]
}

@test "db-migrate fails when one of the backend migration tasks fails" {
  cat > "$run_task_stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/run-task-calls.txt"
case "$*" in
  *'"value":"uk"'*) exit 1 ;;
esac
STUB
  chmod +x "$run_task_stub"

  run run_db_migrate \
    --app-name tariff-backend \
    --environment development \
    --ref abc123

  [ "$status" -eq 1 ]
}

@test "db-migrate requires app name environment and ref" {
  run "$repo_root/bin/db-migrate" --app-name tariff-admin --environment development

  [ "$status" -eq 1 ]
  assert_contains "$output" "Usage:"
}
