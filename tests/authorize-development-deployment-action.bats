#!/usr/bin/env bats

load test_helper

setup() {
  action="$repo_root/.github/actions/authorize-development-deployment/action.yml"
}

@test "deployment authorization reads the current default branch without persisting credentials" {
  run grep -Fx '        ref: ${{ github.event.repository.default_branch }}' "$action"
  [ "$status" -eq 0 ]
  run grep -Fx '        persist-credentials: false' "$action"
  [ "$status" -eq 0 ]
  run grep -E 'pull_request\.head|id-token|secrets\.' "$action"
  [ "$status" -eq 1 ]
}

@test "deployment authorization loads its own script and the caller account list" {
  run grep -Fx '        AUTHORIZATION_SCRIPT: ${{ github.action_path }}/authorize.cjs' "$action"
  [ "$status" -eq 0 ]
  run grep -Fx '        APPROVED_ACCOUNTS_FILE: ${{ inputs.approved-accounts-file }}' "$action"
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
