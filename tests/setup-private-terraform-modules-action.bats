#!/usr/bin/env bats

load test_helper

setup() {
  action="$repo_root/.github/actions/setup-private-terraform-modules/action.yml"
  modules_repo="trade-tariff-platform-terraform-modules"
}

first_line_of() {
  grep -n -F -- "$1" "$2" | head -1 | cut -d: -f1
}

@test "the token is minted only when both app credentials are given" {
  run grep -Fx "      if: \${{ inputs.app-id != '' && inputs.private-key != '' }}" "$action"
  [ "$status" -eq 0 ]
}

@test "the git rewrite runs only when a token was minted" {
  run grep -Fx "      if: \${{ steps.token.outputs.token != '' }}" "$action"
  [ "$status" -eq 0 ]
}

@test "both inputs are optional and default to empty" {
  run grep -Fx -A 3 '  app-id:' "$action"
  assert_contains "$output" '    required: false'
  assert_contains "$output" "    default: ''"

  run grep -Fx -A 3 '  private-key:' "$action"
  assert_contains "$output" '    required: false'
  assert_contains "$output" "    default: ''"
}

@test "the token can only read the Terraform modules repo" {
  run grep -Fx '        owner: trade-tariff' "$action"
  [ "$status" -eq 0 ]
  run grep -Fx "        repositories: $modules_repo" "$action"
  [ "$status" -eq 0 ]
  run grep -Fx '        permission-contents: read' "$action"
  [ "$status" -eq 0 ]

  # No other permission may be requested.
  run grep -E '^[[:space:]]+permission-' "$action"
  [ "$output" = '        permission-contents: read' ]
}

@test "the git rewrite changes only the modules repo URL" {
  local home_dir script
  home_dir="$(mktemp -d)"
  script="$home_dir/rewrite.sh"

  # Take the run block of the rewrite step out of the action file.
  awk '/^      run: \|/ {found=1; next} found && /^        / {sub(/^        /, ""); print; next} found {exit}' "$action" > "$script"
  [ -s "$script" ]

  HOME="$home_dir" GIT_CONFIG_NOSYSTEM=1 TOKEN=dummy-token bash "$script"

  run env HOME="$home_dir" GIT_CONFIG_NOSYSTEM=1 git ls-remote --get-url "https://github.com/trade-tariff/$modules_repo.git"
  # Build the expected URL in parts so secret scanners do not flag a fake token.
  local user_info="x-access-token:dummy-token"
  [ "$output" = "https://${user_info}@github.com/trade-tariff/$modules_repo.git" ]

  run env HOME="$home_dir" GIT_CONFIG_NOSYSTEM=1 git ls-remote --get-url "https://github.com/trade-tariff/trade-tariff-backend.git"
  [ "$output" = "https://github.com/trade-tariff/trade-tariff-backend.git" ]

  rm -rf "$home_dir"
}

@test "plan, apply, destroy and rollback log in before terraform init" {
  local name file login init
  for name in terraform-plan terraform-apply terraform-destroy rollback; do
    file="$repo_root/.github/actions/$name/action.yml"
    login="$(first_line_of 'setup-private-terraform-modules@main' "$file")"
    init="$(first_line_of 'terraform init' "$file")"
    [ -n "$login" ] || fail "$name does not call the login action"
    [ -n "$init" ] || fail "$name has no terraform init"
    [ "$login" -lt "$init" ] || fail "$name logs in after terraform init"

    run grep -F 'app-id: ${{ inputs.modules-app-id }}' "$file"
    [ "$status" -eq 0 ]
    run grep -F 'private-key: ${{ inputs.modules-app-private-key }}' "$file"
    [ "$status" -eq 0 ]
  done
}

@test "plan, apply, destroy and rollback make the module inputs optional" {
  local name file
  for name in terraform-plan terraform-apply terraform-destroy rollback; do
    file="$repo_root/.github/actions/$name/action.yml"
    run grep -Fx -A 3 '  modules-app-id:' "$file"
    assert_contains "$output" '    required: false'
    assert_contains "$output" "    default: ''"
    run grep -Fx -A 3 '  modules-app-private-key:' "$file"
    assert_contains "$output" '    required: false'
    assert_contains "$output" "    default: ''"
  done
}

@test "the deploy workflows log in before db-migrate and forward both secrets" {
  local name file login migrate
  for name in deploy-ecs deploy-ecs-v2; do
    file="$repo_root/.github/workflows/$name.yml"
    login="$(first_line_of 'setup-private-terraform-modules@main' "$file")"
    migrate="$(first_line_of 'actions/db-migrate@main' "$file")"
    [ -n "$login" ] || fail "$name does not log in before migrations"
    [ "$login" -lt "$migrate" ] || fail "$name logs in after db-migrate"

    # plan, apply and rollback each get both secrets.
    run grep -c 'modules-app-id: ' "$file"
    [ "$output" -eq 3 ]
    run grep -c 'modules-app-private-key: ' "$file"
    [ "$output" -eq 3 ]
  done
}

@test "the deploy workflows declare the module secrets as optional" {
  local name file
  for name in deploy-ecs deploy-ecs-v2 destroy-ecs; do
    file="$repo_root/.github/workflows/$name.yml"
    run grep -Fx -A 2 '      modules-app-id:' "$file"
    assert_contains "$output" 'required: false'
    run grep -Fx -A 2 '      modules-app-private-key:' "$file"
    assert_contains "$output" 'required: false'
  done
}

@test "destroy-ecs forwards both secrets to terraform-destroy" {
  local file="$repo_root/.github/workflows/destroy-ecs.yml"
  run grep -F 'modules-app-id: ${{ secrets.modules-app-id }}' "$file"
  [ "$status" -eq 0 ]
  run grep -F 'modules-app-private-key: ${{ secrets.modules-app-private-key }}' "$file"
  [ "$status" -eq 0 ]
}
