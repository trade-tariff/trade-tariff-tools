#!/usr/bin/env bats

load test_helper

@test "db-migrate passes the updated task definition ARN to every migration task" {
  action="$repo_root/.github/actions/db-migrate/action.yml"

  run grep -F "id: update-job-task" "$action"
  [ "$status" -eq 0 ]

  run grep -F "task-definition-arn=" "$action"
  [ "$status" -eq 0 ]

  count=$(grep -F -c -- '-d ${{ steps.update-job-task.outputs.task-definition-arn }}' "$action" || true)
  [ "$count" -eq 3 ]
}
