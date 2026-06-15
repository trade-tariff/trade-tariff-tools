#!/usr/bin/env bats

load test_helper

setup() {
  source "$repo_root/scripts/ecs-task-definition-inventory.sh"
}

@test "task_definition_family returns the exact family from an ARN" {
  run task_definition_family "arn:aws:ecs:eu-west-2:123456789012:task-definition/admin-job:7"

  [ "$status" -eq 0 ]
  [ "$output" = "admin-job" ]
}

@test "task_definition_family returns the exact family from an account-suffixed ARN" {
  run task_definition_family "arn:aws:ecs:eu-west-2:123456789012:task-definition/backend-job-123456789012:42"

  [ "$status" -eq 0 ]
  [ "$output" = "backend-job-123456789012" ]
}

@test "family_is_preserved preserves job families with and without account suffixes" {
  family_is_preserved "admin-job"
  family_is_preserved "admin-job-123456789012"
}

@test "family_is_preserved does not preserve non-job families" {
  if family_is_preserved "admin"; then
    fail "admin should not be preserved"
  fi

  if family_is_preserved "admin-worker"; then
    fail "admin-worker should not be preserved"
  fi
}
