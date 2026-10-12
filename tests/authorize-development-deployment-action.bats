#!/usr/bin/env bats

load test_helper

setup() {
  action="$repo_root/.github/actions/authorize-development-deployment/action.yml"
}

@test "deployment authorization cannot read a caller or PR account list" {
  run grep -E 'actions/checkout|approved-accounts-file|readFileSync|id-token|secrets\.' "$action"
  [ "$status" -eq 1 ]
}

@test "deployment authorization loads its own script and checks the rerun account" {
  run grep -Fx '        AUTHORIZATION_SCRIPT: ${{ github.action_path }}/authorize.cjs' "$action"
  [ "$status" -eq 0 ]
  run grep -Fx '        TRIGGERING_ACTOR: ${{ github.triggering_actor }}' "$action"
  [ "$status" -eq 0 ]
  run grep -Fx '          const authorize = require(process.env.AUTHORIZATION_SCRIPT);' "$action"
  [ "$status" -eq 0 ]
}

@test "deployment authorization exposes only the authorized commit to the caller" {
  run grep -Fx '    value: ${{ steps.authorize.outputs.sha }}' "$action"
  [ "$status" -eq 0 ]
}
