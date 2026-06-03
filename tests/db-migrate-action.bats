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

@test "db-migrate derives the job task from the deployed app name" {
  action="$repo_root/.github/actions/db-migrate/action.yml"

  run grep -F "app-name:" "$action"
  [ "$status" -eq 0 ]

  run grep -F 'REPO="${{ inputs.app-name }}"' "$action"
  [ "$status" -eq 0 ]

  run grep -F 'REPO="${REPO#tariff-}"' "$action"
  [ "$status" -eq 0 ]

  run grep -F 'echo "repo=${REPO}"' "$action"
  [ "$status" -eq 0 ]
}

@test "db-migrate does not checkout the caller repository" {
  action="$repo_root/.github/actions/db-migrate/action.yml"

  run grep -F "actions/checkout" "$action"
  [ "$status" -ne 0 ]
}

@test "deploy-ecs passes the deployed app name to db-migrate" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "app-name: \${{ inputs.app-name }}" "$workflow"
  [ "$status" -eq 0 ]
}

@test "deploy-multi-ecs only migrates apps that explicitly opt in" {
  workflow="$repo_root/.github/workflows/deploy-multi-ecs.yml"

  run grep -F "migrate: \${{ inputs.migrate && toJson(matrix.app.migrate) == 'true' }}" "$workflow"
  [ "$status" -eq 0 ]
}
