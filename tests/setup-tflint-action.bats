#!/usr/bin/env bats

load test_helper

setup() {
  action="$repo_root/.github/actions/setup-tflint/action.yml"
}

@test "setup-tflint uses the SHA-pinned official setup action" {
  run grep -Fx '      uses: terraform-linters/setup-tflint@90f302c255ef959cbfb4bd10581afecdb7ece3e6 # v4.1.1' "$action"
  [ "$status" -eq 0 ]
}

@test "setup-tflint does not run a curl or shell installer" {
  run grep -En 'curl|install_linux\.sh|^[[:space:]]*(run|shell):|\|[[:space:]]*bash' "$action"
  [ "$status" -eq 1 ]
}

@test "setup-tflint preserves its optional empty token input and composite interface" {
  run grep -Fx -A 3 '  github-token:' "$action"
  [ "$status" -eq 0 ]
  assert_contains "$output" "    description: 'GitHub token for API authentication'"
  assert_contains "$output" '    required: false'
  assert_contains "$output" "    default: ''"

  run grep -Fx "  using: 'composite'" "$action"
  [ "$status" -eq 0 ]
}

@test "setup-tflint prefers the caller token and falls back to the workflow token" {
  run grep -Fx '        github_token: ${{ inputs.github-token || github.token }}' "$action"
  [ "$status" -eq 0 ]

  run grep -Ei 'secrets\.' "$action"
  [ "$status" -eq 1 ]
}

@test "setup-tflint explicitly installs the latest version" {
  run grep -Fx '        tflint_version: latest' "$action"
  [ "$status" -eq 0 ]
}

@test "setup-tflint disables the wrapper" {
  run grep -Fx '        tflint_wrapper: false' "$action"
  [ "$status" -eq 0 ]
}
