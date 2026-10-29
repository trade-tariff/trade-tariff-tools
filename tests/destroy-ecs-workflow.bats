#!/usr/bin/env bats

load test_helper

@test "destroy-ecs refuses every environment except uat" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("destroy").fetch("steps")
    guard = steps.first
    abort "The first step must be the uat guard" unless guard.fetch("name") == "Allow only uat"
    abort "The guard must compare the environment with uat" unless guard.fetch("run").include?(%q{"$ENVIRONMENT" != "uat"})
    abort "The guard must fail the job" unless guard.fetch("run").include?("exit 1")
  ' "$repo_root/.github/workflows/destroy-ecs.yml"

  [ "$status" -eq 0 ]
}

@test "destroy-ecs uses the deploy role from configure-environment" {
  workflow="$repo_root/.github/workflows/destroy-ecs.yml"

  run grep -F "trade-tariff/trade-tariff-tools/.github/actions/configure-environment@main" "$workflow"
  [ "$status" -eq 0 ]

  run grep -F "role-to-assume: \${{ steps.environment-config.outputs.deploy-role-arn }}" "$workflow"
  [ "$status" -eq 0 ]
}

@test "terraform-destroy uses the environment backend and var file" {
  action="$repo_root/.github/actions/terraform-destroy/action.yml"

  run grep -F "terraform init -backend-config=backends/\${{ inputs.environment }}.tfbackend" "$action"
  [ "$status" -eq 0 ]

  run grep -F "terraform destroy -var-file=config_\${{ inputs.environment }}.tfvars -auto-approve" "$action"
  [ "$status" -eq 0 ]
}

@test "terraform-destroy refuses every environment except uat" {
  run ruby -ryaml -e '
    guard = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").first
    abort "The first step must be the uat guard" unless guard.fetch("name") == "Allow only uat"
    abort "The guard must compare the environment with uat" unless guard.fetch("run").include?(%q{"$ENVIRONMENT" != "uat"})
    abort "The guard must fail the step" unless guard.fetch("run").include?("exit 1")
  ' "$repo_root/.github/actions/terraform-destroy/action.yml"

  [ "$status" -eq 0 ]
}

@test "terraform-destroy force-unlocks only a lock that this runner holds" {
  action="$repo_root/.github/actions/terraform-destroy/action.yml"

  run grep -F "\"\$(jq -r '.Who' /tmp/terraform.tflock)\" != \"\$(whoami)@\$(hostname)\"" "$action"
  [ "$status" -eq 0 ]
}

@test "terraform-destroy sets the Terraform version directly" {
  action="$repo_root/.github/actions/terraform-destroy/action.yml"

  run grep -F "terraform_version: 1.12" "$action"
  [ "$status" -eq 0 ]

  run grep -F "env.TERRAFORM_VERSION" "$action"
  [ "$status" -ne 0 ]
}
