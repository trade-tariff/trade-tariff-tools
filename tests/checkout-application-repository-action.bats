#!/usr/bin/env bats

load test_helper

setup() {
  action="$repo_root/.github/actions/checkout-application-repository/action.yml"
  workflows="$repo_root/.github/workflows"
  new_action='trade-tariff/trade-tariff-tools/.github/actions/checkout-application-repository@main'
}

@test "the token is minted only with app credentials and only for another repo" {
  run grep -Fx "      if: \${{ inputs.app-id != '' && inputs.private-key != '' && inputs.repository != github.repository }}" "$action"
  [ "$status" -eq 0 ]
}

@test "the token can only read the one repo that is checked out" {
  run grep -Fx '        owner: ${{ steps.target.outputs.owner }}' "$action"
  [ "$status" -eq 0 ]
  run grep -Fx '        repositories: ${{ steps.target.outputs.name }}' "$action"
  [ "$status" -eq 0 ]
  run grep -Fx '        permission-contents: read' "$action"
  [ "$status" -eq 0 ]

  # No other permission may be requested.
  run grep -E '^[[:space:]]+permission-' "$action"
  [ "$output" = '        permission-contents: read' ]
}

@test "checkout uses the app token when there is one and the default token otherwise" {
  run grep -Fx '        token: ${{ steps.token.outputs.token || github.token }}' "$action"
  [ "$status" -eq 0 ]
}

@test "the optional inputs default to a plain checkout of the repo" {
  local input
  for input in ref app-id private-key; do
    run grep -Fx -A 3 "  ${input}:" "$action"
    assert_contains "$output" '    required: false'
    assert_contains "$output" "    default: ''"
  done
  run grep -Fx -A 3 '  fetch-depth:' "$action"
  assert_contains "$output" "    default: '1'"
}

@test "the repository is split into owner and name" {
  local script outputs
  script="$(mktemp)"
  outputs="$(mktemp)"

  awk '/^      run: \|/ {found=1; next} found && /^        / {sub(/^        /, ""); print; next} found {exit}' "$action" > "$script"
  [ -s "$script" ]

  REPOSITORY=trade-tariff/trade-tariff-backend GITHUB_OUTPUT="$outputs" bash "$script"
  [ "$(cat "$outputs")" = "$(printf 'owner=trade-tariff\nname=trade-tariff-backend')" ]

  rm -f "$script" "$outputs"
}

@test "deploy-ecs and deploy-ecs-v2 never use the default token for an app repo" {
  local name file
  for name in deploy-ecs deploy-ecs-v2 destroy-ecs; do
    file="$workflows/$name.yml"
    run awk '/uses: "?actions\/checkout@/ {getline a; getline b; getline c; if ((b c) ~ /actual_repo|checkout-repo/) print}' "$file"
    [ -z "$output" ] || fail "$name still checks out an app repo with the default token"
  done
}

@test "every app repo checkout gets both app secrets" {
  local name file
  for name in deploy-ecs deploy-ecs-v2; do
    file="$workflows/$name.yml"
    run grep -c -F "$new_action" "$file"
    [ "$output" -eq 6 ]
    run grep -c -F 'secrets.checkout-app-id' "$file"
    [ "$output" -eq 6 ]
    run grep -c -F 'secrets.checkout-app-private-key' "$file"
    [ "$output" -eq 6 ]
  done

  file="$workflows/destroy-ecs.yml"
  run grep -c -F "$new_action" "$file"
  [ "$output" -eq 1 ]
  run grep -c -F 'secrets.checkout-app-id' "$file"
  [ "$output" -eq 1 ]
  run grep -c -F 'secrets.checkout-app-private-key' "$file"
  [ "$output" -eq 1 ]
}

@test "the workflows keep the tools self-checkout on the default token" {
  run grep -c 'actions/checkout@' "$workflows/deploy-ecs.yml"
  [ "$output" -eq 1 ]
  run grep -c 'actions/checkout@' "$workflows/deploy-ecs-v2.yml"
  [ "$output" -eq 1 ]
}

@test "the workflows declare the checkout secrets as optional" {
  local name file
  for name in deploy-ecs deploy-ecs-v2 destroy-ecs deploy-multi-ecs deploy-multi-ecs-v2; do
    file="$workflows/$name.yml"
    run grep -Fx -A 2 '      checkout-app-id:' "$file"
    assert_contains "$output" 'required: false'
    run grep -Fx -A 2 '      checkout-app-private-key:' "$file"
    assert_contains "$output" 'required: false'
  done
}

@test "the multi-app workflows forward all four app secrets to the deploy workflow" {
  local name file secret
  for name in deploy-multi-ecs deploy-multi-ecs-v2; do
    file="$workflows/$name.yml"
    for secret in modules-app-id modules-app-private-key checkout-app-id checkout-app-private-key; do
      run grep -E "^      ${secret}: \"?\\\$\{\{ secrets\.${secret} \}\}\"?$" "$file"
      [ "$status" -eq 0 ] || fail "$name does not forward $secret"
    done
  done
}
