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

@test "terraform-destroy sets the Terraform version directly" {
  action="$repo_root/.github/actions/terraform-destroy/action.yml"

  run grep -F "terraform_version: 1.12" "$action"
  [ "$status" -eq 0 ]

  run grep -F "env.TERRAFORM_VERSION" "$action"
  [ "$status" -ne 0 ]
}

# Prints the run script and the ENVIRONMENT mapping of the first step of a workflow job or an action.
guard_step() {
  ruby -ryaml -e '
    doc = YAML.load_file(ARGV.fetch(0))
    steps = doc.key?("runs") ? doc.fetch("runs").fetch("steps") : doc.fetch("jobs").fetch("destroy").fetch("steps")
    guard = steps.first
    File.write(ARGV.fetch(1), guard.fetch("run"))
    puts guard.fetch("env").fetch("ENVIRONMENT")
  ' "$1" "$2"
}

@test "the uat guards map ENVIRONMENT to the environment input" {
  tmpdir="$(mktemp -d)"

  for file in .github/workflows/destroy-ecs.yml .github/actions/terraform-destroy/action.yml; do
    run guard_step "$repo_root/$file" "$tmpdir/guard.sh"
    [ "$status" -eq 0 ]
    [ "$output" = '${{ inputs.environment }}' ]
  done

  rm -rf "$tmpdir"
}

@test "the uat guards allow uat and refuse other environments" {
  tmpdir="$(mktemp -d)"

  for file in .github/workflows/destroy-ecs.yml .github/actions/terraform-destroy/action.yml; do
    guard_step "$repo_root/$file" "$tmpdir/guard.sh" > /dev/null

    run env ENVIRONMENT=uat bash "$tmpdir/guard.sh"
    [ "$status" -eq 0 ]

    for environment in development staging production ""; do
      run env ENVIRONMENT="$environment" bash "$tmpdir/guard.sh"
      [ "$status" -eq 1 ]
      assert_contains "$output" "runs only for uat"
    done
  done

  rm -rf "$tmpdir"
}

setup_unlock() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  unlock_script="$repo_root/.github/actions/terraform-destroy/force-unlock-own-lock.sh"

  mkdir -p "$tmpdir/app/terraform/backends"
  cat > "$tmpdir/app/terraform/backends/uat.tfbackend" <<'BACKEND'
bucket = "terraform-state-uat-352285845378"
key    = "backend/terraform.tfstate"
BACKEND

  # Copies $LOCK_FIXTURE to the destination, or fails when the lock is missing.
  cat > "$stub_bin/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_CAPTURE_DIR/aws-args.txt"
[[ -n "${LOCK_FIXTURE:-}" ]] || exit 1
cp "$LOCK_FIXTURE" "$4"
STUB

  cat > "$stub_bin/terraform" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$PWD" "$@" > "$TEST_CAPTURE_DIR/terraform-args.txt"
STUB

  printf '#!/usr/bin/env bash\necho runner\n' > "$stub_bin/whoami"
  printf '#!/usr/bin/env bash\necho runner-host\n' > "$stub_bin/hostname"
  chmod +x "$stub_bin"/*
}

@test "force-unlock-own-lock removes a lock that this runner holds" {
  setup_unlock
  echo '{"ID": "lock-123", "Who": "runner@runner-host"}' > "$tmpdir/lock.json"

  cd "$tmpdir/app"
  run env ENVIRONMENT=uat LOCK_FIXTURE="$tmpdir/lock.json" "$unlock_script"

  [ "$status" -eq 0 ]
  assert_contains "$(cat "$tmpdir/aws-args.txt")" "s3://terraform-state-uat-352285845378/backend/terraform.tfstate.tflock"
  [ "$(cat "$tmpdir/terraform-args.txt")" = "$(printf '%s\nforce-unlock\n-force\nlock-123' "$tmpdir/app/terraform")" ]
  rm -rf "$tmpdir"
}

@test "force-unlock-own-lock keeps a lock that another run holds" {
  setup_unlock
  echo '{"ID": "lock-456", "Who": "runner@other-host"}' > "$tmpdir/lock.json"

  cd "$tmpdir/app"
  run env ENVIRONMENT=uat LOCK_FIXTURE="$tmpdir/lock.json" "$unlock_script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "belongs to another run"
  [ ! -f "$tmpdir/terraform-args.txt" ]
  rm -rf "$tmpdir"
}

@test "force-unlock-own-lock succeeds when there is no lock" {
  setup_unlock

  cd "$tmpdir/app"
  run env ENVIRONMENT=uat "$unlock_script"

  [ "$status" -eq 0 ]
  assert_contains "$output" "No state lock to remove"
  [ ! -f "$tmpdir/terraform-args.txt" ]
  rm -rf "$tmpdir"
}

@test "force-unlock-own-lock requires ENVIRONMENT" {
  setup_unlock

  run env -u ENVIRONMENT "$unlock_script"

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required environment variable: ENVIRONMENT"
  rm -rf "$tmpdir"
}

@test "terraform-destroy runs force-unlock-own-lock only on cancellation" {
  run ruby -ryaml -e '
    step = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps").last
    abort "wrong condition" unless step.fetch("if") == "cancelled()"
    abort "wrong script" unless step.fetch("run").include?("force-unlock-own-lock.sh")
    abort "wrong environment" unless step.fetch("env").fetch("ENVIRONMENT") == "${{ inputs.environment }}"
  ' "$repo_root/.github/actions/terraform-destroy/action.yml"

  [ "$status" -eq 0 ]
}
