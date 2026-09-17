#!/usr/bin/env bats

load test_helper

@test "db-migrate action delegates migration orchestration to bin/db-migrate" {
  action="$repo_root/.github/actions/db-migrate/action.yml"

  run grep -F "../../../bin/db-migrate" "$action"
  [ "$status" -eq 0 ]

  run grep -F -- 'APP_NAME: ${{ inputs.app-name }}' "$action"
  [ "$status" -eq 0 ]

  run grep -F -- 'ENVIRONMENT: ${{ inputs.environment }}' "$action"
  [ "$status" -eq 0 ]

  run grep -F -- 'REF: ${{ inputs.ref }}' "$action"
  [ "$status" -eq 0 ]

  run grep -F -- '--app-name "$APP_NAME"' "$action"
  [ "$status" -eq 0 ]

  run grep -F -- '--environment "$ENVIRONMENT"' "$action"
  [ "$status" -eq 0 ]

  run grep -F -- '--ref "$REF"' "$action"
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

  run grep -F -- 'APP_NAME: ${{ inputs.app-name }}' "$action"
  [ "$status" -eq 0 ]

  run grep -F -- '--app-name "$APP_NAME"' "$action"
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

@test "db-migrate action passes the previous ref to the command" {
  action="$repo_root/.github/actions/db-migrate/action.yml"

  run grep -F "previous-ref:" "$action"
  [ "$status" -eq 0 ]

  run grep -F -- 'PREVIOUS_REF: ${{ inputs.previous-ref }}' "$action"
  [ "$status" -eq 0 ]

  run grep -F -- 'args+=(--previous-ref "$PREVIOUS_REF")' "$action"
  [ "$status" -eq 0 ]
}

@test "db-migrate action does not interpolate inputs into the generated shell" {
  action="$repo_root/.github/actions/db-migrate/action.yml"

  run awk '
    $0 ~ /^[[:space:]]*run:/ { in_run=1; next }
    in_run && $0 ~ /^[[:space:]]{4}[^[:space:]]/ { in_run=0 }
    in_run && $0 ~ /\$\{\{ inputs\./ { found=1 }
    END { exit found ? 0 : 1 }
  ' "$action"
  [ "$status" -ne 0 ]
}

@test "db-migrate initialises terraform after the skip check" {
  script="$repo_root/bin/db-migrate"
  action="$repo_root/.github/actions/db-migrate/action.yml"

  run grep -F 'terraform init -backend-config="backends/${environment}.tfbackend"' "$script"
  [ "$status" -eq 0 ]

  run grep -F "terraform init" "$action"
  [ "$status" -ne 0 ]
}

@test "deploy-ecs passes the previous docker tag to db-migrate" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F "previous-ref: \${{ needs.configure.outputs.previous_docker_tag }}" "$workflow"
  [ "$status" -eq 0 ]
}

@test "deploy-ecs fetches full history before db-migrate" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run awk '
    /uses: actions\/checkout@v7.0.1/ { checkout=1; depth=0; next }
    checkout && /fetch-depth: 0/ { depth=1 }
    checkout && /uses: trade-tariff\/trade-tariff-tools\/.github\/actions\/db-migrate/ {
      exit depth ? 0 : 1
    }
  ' "$workflow"
  [ "$status" -eq 0 ]
}

@test "deploy-ecs matches services named without the tariff- prefix" {
  workflow="$repo_root/.github/workflows/deploy-ecs.yml"

  run grep -F 'REPO_NAME="${APP_NAME#tariff-}"' "$workflow"
  [ "$status" -eq 0 ]

  run grep -F -- 'if [[ "$SERVICE_NAME" == ${APP_NAME}* || "$SERVICE_NAME" == ${REPO_NAME}* ]]; then' "$workflow"
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
