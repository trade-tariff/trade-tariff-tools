#!/usr/bin/env bats

load test_helper

@test "service control actions use configure-environment outputs" {
  start_action="$repo_root/.github/actions/start-services/action.yml"
  stop_action="$repo_root/.github/actions/stop-services/action.yml"

  run grep -F "trade-tariff/trade-tariff-tools/.github/actions/configure-environment@main" "$start_action"
  [ "$status" -eq 0 ]

  run grep -F "role-to-assume: \${{ steps.config.outputs.deploy-role-arn }}" "$start_action"
  [ "$status" -eq 0 ]

  run grep -F "CLUSTER=\"\${{ steps.config.outputs.cluster }}\"" "$start_action"
  [ "$status" -eq 0 ]

  run grep -F "trade-tariff/trade-tariff-tools/.github/actions/configure-environment@main" "$stop_action"
  [ "$status" -eq 0 ]

  run grep -F "role-to-assume: \${{ steps.config.outputs.deploy-role-arn }}" "$stop_action"
  [ "$status" -eq 0 ]

  run grep -F "CLUSTER=\"\${{ steps.config.outputs.cluster }}\"" "$stop_action"
  [ "$status" -eq 0 ]
}

@test "deploy workflow uses configure-environment for deployment outputs" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "id: environment-config" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "ecr_url=\${{ steps.environment-config.outputs.ecr-url }}" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "iam_role_arn=\${{ steps.environment-config.outputs.deploy-role-arn }}" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "slack_channel=\${{ steps.environment-config.outputs.slack-channel }}" "$workflow"
  [ "$status" -eq 0 ]
}

@test "task definition maintenance workflows use cleanup role from configure-environment" {
  cleanup_workflow="$repo_root/.github/workflows/cleanup-unused-task-families.yml"
  rotate_workflow="$repo_root/.github/workflows/rotate-task-definitions.yml"

  cleanup_count=$(grep -F -c "trade-tariff/trade-tariff-tools/.github/actions/configure-environment@main" "$cleanup_workflow" || true)
  [ "$cleanup_count" -eq 3 ]

  rotate_count=$(grep -F -c "trade-tariff/trade-tariff-tools/.github/actions/configure-environment@main" "$rotate_workflow" || true)
  [ "$rotate_count" -eq 3 ]

  run grep -F "role-to-assume: \${{ steps.config.outputs.cleanup-role-arn }}" "$cleanup_workflow"
  [ "$status" -eq 0 ]

  run grep -F "role-to-assume: \${{ steps.config.outputs.cleanup-role-arn }}" "$rotate_workflow"
  [ "$status" -eq 0 ]
}
