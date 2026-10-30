#!/usr/bin/env bats

load test_helper

setup() {
  workdir="$(mktemp -d)"
  mkdir -p "$workdir/bin" "$workdir/terraform"
  cat > "$workdir/bin/terraform" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
STUB
  chmod +x "$workdir/bin/terraform"
  apply="$repo_root/.github/actions/terraform-apply/apply.sh"
}

teardown() {
  rm -rf "$workdir"
}

@test "apply.sh puts each var after the var file" {
  cd "$workdir"
  ENVIRONMENT=uat VARS=$'start_without_tasks=true\n\nservice_count=0' PATH="$workdir/bin:$PATH" run "$apply"

  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' apply -var-file=config_uat.tfvars -var start_without_tasks=true -var service_count=0 -auto-approve -lock-timeout=10m)" ]
}

@test "apply.sh adds no var without vars" {
  cd "$workdir"
  ENVIRONMENT=uat PATH="$workdir/bin:$PATH" run "$apply"

  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' apply -var-file=config_uat.tfvars -auto-approve -lock-timeout=10m)" ]
}

@test "apply.sh requires ENVIRONMENT" {
  cd "$workdir"
  PATH="$workdir/bin:$PATH" run "$apply"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: ENVIRONMENT"
}

@test "terraform-apply runs apply.sh with the environment and vars" {
  action="$repo_root/.github/actions/terraform-apply/action.yml"

  run grep -F "run: '\"\${{ github.action_path }}/apply.sh\"'" "$action"
  [ "$status" -eq 0 ]

  run grep -F 'VARS: ${{ inputs.vars }}' "$action"
  [ "$status" -eq 0 ]
}

@test "deploy-ecs passes terraform-vars to terraform-apply" {
  run grep -F 'vars: ${{ inputs.terraform-vars }}' "$repo_root/.github/workflows/deploy-ecs.yml"
  [ "$status" -eq 0 ]
}
