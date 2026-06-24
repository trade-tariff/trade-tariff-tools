#!/usr/bin/env bats

load test_helper

@test "db-migrate action delegates migration orchestration to bin/db-migrate" {
  action="$repo_root/.github/actions/db-migrate/action.yml"

  run grep -F "../../../bin/db-migrate" "$action"
  [ "$status" -eq 0 ]

  run grep -F -- "--app-name \${{ inputs.app-name }}" "$action"
  [ "$status" -eq 0 ]

  run grep -F -- "--environment \${{ inputs.environment }}" "$action"
  [ "$status" -eq 0 ]

  run grep -F -- "--ref \${{ inputs.ref }}" "$action"
  [ "$status" -eq 0 ]
}

@test "db-migrate command derives the job task from the deployed app name" {
  script="$repo_root/bin/db-migrate"

  run grep -F 'repo="${app_name#tariff-}"' "$script"
  [ "$status" -eq 0 ]

  run grep -F 'task="${repo}-job"' "$script"
  [ "$status" -eq 0 ]
}

@test "db-migrate action passes the deployed app name to the command" {
  action="$repo_root/.github/actions/db-migrate/action.yml"

  run grep -F "app-name:" "$action"
  [ "$status" -eq 0 ]

  run grep -F -- "--app-name \${{ inputs.app-name }}" "$action"
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

@test "deploy-multi-ecs passes the WAF bypass token to tariff e2e tests" {
  workflow="$repo_root/.github/workflows/deploy-multi-ecs.yml"

  run grep -F "waf_bypass_token:" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "waf_bypass_token: \${{ secrets.waf_bypass_token }}" "$workflow"
  [ "$status" -eq 0 ]
}
