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
  init)
    exit 0
    ;;
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

  assert_contains "$terraform_calls" "init -backend-config=backends/development.tfbackend"
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
  # Each stub records that it started, then waits for the other schema's
  # start marker before recording overlap. Sequential execution cannot
  # produce both overlap markers because the second stub never starts
  # until the first has finished waiting.
  cat > "$run_task_stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/run-task-calls.txt"
service="unknown"
case "$*" in
  *'"value":"uk"'*) service="uk" ;;
  *'"value":"xi"'*) service="xi" ;;
esac
touch "$TEST_CAPTURE_DIR/started-$service"
i=0
while [ ! -f "$TEST_CAPTURE_DIR/started-uk" ] || [ ! -f "$TEST_CAPTURE_DIR/started-xi" ]; do
  i=$((i + 1))
  if [ "$i" -gt 50 ]; then
    exit 0
  fi
  sleep 0.1
done
touch "$TEST_CAPTURE_DIR/overlapped-$service"
STUB
  chmod +x "$run_task_stub"

  run run_db_migrate \
    --app-name tariff-backend \
    --environment development \
    --ref abc123

  [ "$status" -eq 0 ]
  [ -f "$tmpdir/overlapped-uk" ]
  [ -f "$tmpdir/overlapped-xi" ]
}

@test "db-migrate prints each backend migration's logs as a block" {
  cat > "$run_task_stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/run-task-calls.txt"
case "$*" in
  *'"value":"uk"'*)
    echo UK-START
    sleep 0.2
    echo UK-END
    ;;
  *'"value":"xi"'*)
    echo XI-START
    echo XI-END
    ;;
esac
STUB
  chmod +x "$run_task_stub"

  run run_db_migrate \
    --app-name tariff-backend \
    --environment development \
    --ref abc123

  [ "$status" -eq 0 ]
  [[ "$output" == *"UK-START"*"UK-END"*"XI-START"*"XI-END"* ]]
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

# Create a git repository in the project directory with a base commit that
# contains migration files. Prints the short sha of the base commit.
setup_migration_repo() {
  (
    cd "$tmpdir/project"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    mkdir -p db/migrate db/data_migrate
    echo "class Initial" > db/migrate/20260101000000_initial.rb
    git add -A
    git commit -qm "base"
  )
  git -C "$tmpdir/project" rev-parse --short HEAD
}

commit_app_change() {
  (
    cd "$tmpdir/project"
    echo "change" >> app_change.txt
    git add -A
    git commit -qm "app change only"
  )
  git -C "$tmpdir/project" rev-parse --short HEAD
}

commit_migration_change() {
  (
    cd "$tmpdir/project"
    echo "class Second" > db/data_migrate/20260201000000_second.rb
    git add -A
    git commit -qm "add data migration"
  )
  git -C "$tmpdir/project" rev-parse --short HEAD
}

@test "db-migrate skips when no migration file changed since the previous ref" {
  local previous current
  previous="$(setup_migration_repo)"
  current="$(commit_app_change)"

  run run_db_migrate \
    --app-name tariff-backend \
    --environment development \
    --ref "$current" \
    --previous-ref "$previous"

  [ "$status" -eq 0 ]
  assert_contains "$output" "Skipping the database migration tasks"
  [ ! -f "$tmpdir/terraform-calls.txt" ]
  [ ! -f "$tmpdir/run-task-calls.txt" ]
}

@test "db-migrate skips when the previous ref is the same as the deployed ref" {
  local ref
  ref="$(setup_migration_repo)"

  run run_db_migrate \
    --app-name tariff-backend \
    --environment development \
    --ref "$ref" \
    --previous-ref "$ref"

  [ "$status" -eq 0 ]
  assert_contains "$output" "Skipping the database migration tasks"
  [ ! -f "$tmpdir/terraform-calls.txt" ]
  [ ! -f "$tmpdir/run-task-calls.txt" ]
}

@test "db-migrate runs when a data migration file changed since the previous ref" {
  local previous current
  previous="$(setup_migration_repo)"
  current="$(commit_migration_change)"

  run run_db_migrate \
    --app-name tariff-backend \
    --environment development \
    --ref "$current" \
    --previous-ref "$previous"

  [ "$status" -eq 0 ]
  terraform_calls="$(cat "$tmpdir/terraform-calls.txt")"
  assert_contains "$terraform_calls" "apply -var-file=config_development.tfvars"
  run_task_calls="$(cat "$tmpdir/run-task-calls.txt")"
  assert_contains "$run_task_calls" "\"SERVICE\",\"value\":\"uk\""
}

@test "db-migrate runs when the previous ref does not resolve" {
  local current
  current="$(setup_migration_repo)"

  run run_db_migrate \
    --app-name tariff-backend \
    --environment development \
    --ref "$current" \
    --previous-ref 0000000

  [ "$status" -eq 0 ]
  terraform_calls="$(cat "$tmpdir/terraform-calls.txt")"
  assert_contains "$terraform_calls" "apply -var-file=config_development.tfvars"
}
