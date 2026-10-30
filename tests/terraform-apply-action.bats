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

  ruby -ryaml -e '
    step = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").find { |s| s.fetch("run", "").include?("terraform apply") }
    File.write(ARGV.fetch(1), step.fetch("run").gsub("${{ inputs.environment }}", "uat"))
  ' "$repo_root/.github/actions/terraform-apply/action.yml" "$workdir/apply.sh"
}

teardown() {
  rm -rf "$workdir"
}

@test "terraform-apply puts each var after the var file" {
  cd "$workdir"
  VARS=$'start_without_tasks=true\n\nservice_count=0' PATH="$workdir/bin:$PATH" run bash -e -o pipefail apply.sh

  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' apply -var-file=config_uat.tfvars -var start_without_tasks=true -var service_count=0 -auto-approve -lock-timeout=10m)" ]
}

@test "terraform-apply adds no var without vars" {
  cd "$workdir"
  VARS="" PATH="$workdir/bin:$PATH" run bash -e -o pipefail apply.sh

  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' apply -var-file=config_uat.tfvars -auto-approve -lock-timeout=10m)" ]
}

@test "deploy-ecs passes terraform-vars to terraform-apply" {
  run grep -F 'vars: ${{ inputs.terraform-vars }}' "$repo_root/.github/workflows/deploy-ecs.yml"
  [ "$status" -eq 0 ]
}
