#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  output_file="$tmpdir/github-output"
  script="$tmpdir/configure-environment.sh"
  ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").fetch(0).fetch("run")' \
    "$repo_root/.github/actions/configure-environment/action.yml" > "$script"
}

teardown() {
  rm -rf "$tmpdir"
}

run_configure_environment() {
  GITHUB_OUTPUT="$output_file" bash "$script"
}

@test "configure-environment emits development environment outputs" {
  run env \
    ENVIRONMENT="development" \
    APP_NAME="tariff-backend" \
    SERVICE_NAMES="" \
    REGION="eu-west-2" \
    GITHUB_OUTPUT="$output_file" \
    bash "$script"

  [ "$status" -eq 0 ]
  outputs="$(cat "$output_file")"
  assert_contains "$outputs" "account-id=844815912454"
  assert_contains "$outputs" "cluster=trade-tariff-cluster-development"
  assert_contains "$outputs" "security-group-name=trade-tariff-ecs-security-group-development"
  assert_contains "$outputs" "log-group=platform-logs-development"
  assert_contains "$outputs" "slack-channel=deployments"
  assert_contains "$outputs" "deploy-role-arn=arn:aws:iam::844815912454:role/GithubActions-ECS-Deployments-Role"
  assert_contains "$outputs" "cleanup-role-arn=arn:aws:iam::844815912454:role/GithubActions-ECS-Task-Cleanup-Role"
  assert_contains "$outputs" "ecr-url=382373577178.dkr.ecr.eu-west-2.amazonaws.com/tariff-backend-production"
}

@test "configure-environment emits identity deploy role for identity app" {
  run env \
    ENVIRONMENT="production" \
    APP_NAME="tariff-identity" \
    SERVICE_NAMES="" \
    REGION="eu-west-2" \
    GITHUB_OUTPUT="$output_file" \
    bash "$script"

  [ "$status" -eq 0 ]
  outputs="$(cat "$output_file")"
  assert_contains "$outputs" "account-id=382373577178"
  assert_contains "$outputs" "slack-channel=production-deployments"
  assert_contains "$outputs" "deploy-role-arn=arn:aws:iam::382373577178:role/GithubActions-Identity-ECS-Deployments-Role"
}

@test "configure-environment emits identity deploy role for identity service control" {
  run env \
    ENVIRONMENT="staging" \
    APP_NAME="" \
    SERVICE_NAMES="frontend identity backend" \
    REGION="eu-west-2" \
    GITHUB_OUTPUT="$output_file" \
    bash "$script"

  [ "$status" -eq 0 ]
  outputs="$(cat "$output_file")"
  assert_contains "$outputs" "deploy-role-arn=arn:aws:iam::451934005581:role/GithubActions-Identity-ECS-Deployments-Role"
}

@test "configure-environment rejects unknown environments" {
  run env \
    ENVIRONMENT="preview" \
    APP_NAME="tariff-backend" \
    SERVICE_NAMES="" \
    REGION="eu-west-2" \
    GITHUB_OUTPUT="$output_file" \
    bash "$script"

  [ "$status" -eq 1 ]
  assert_contains "$output" "Invalid environment: preview"
}
