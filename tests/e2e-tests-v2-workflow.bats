#!/usr/bin/env bats

load test_helper

setup() {
  export WORKFLOW_FILE="$repo_root/.github/workflows/e2e-tests-v2.yml"
}

@test "E2E workflow forwards project selection and passwordless preference to the launcher" {
  run ruby -ryaml -e '
    workflow = YAML.load_file(ARGV.fetch(0))
    inputs = workflow.fetch(true).fetch("workflow_call").fetch("inputs")
    abort "Projects must default to api,frontend" unless inputs.dig("projects", "default") == "api,frontend"
    abort "Passwordless skipping must default to true" unless inputs.dig("skip-passwordless", "default") == true
    %w[skip-admin skip-dev-hub skip-myott].each do |removed|
      abort "Obsolete project skip input remains: #{removed}" if inputs.key?(removed)
    end
    steps = workflow.fetch("jobs").fetch("test").fetch("steps")
    launcher = steps.find { |step| step["uses"] == "trade-tariff/trade-tariff-tools/.github/actions/run-e2e-tests@main" }
    abort "E2E launcher must be used" unless launcher
    expected = {
      "projects" => "${{ inputs.projects }}",
      "test-environment" => "${{ inputs.test-environment }}",
      "skip-passwordless" => "${{ inputs.skip-passwordless }}"
    }
    abort "E2E launcher inputs changed" unless launcher.fetch("with") == expected
    abort "Quiet dotenv behaviour changed" unless launcher.dig("env", "DOTENV_CONFIG_QUIET") == true
  ' "$WORKFLOW_FILE"

  [ "$status" -eq 0 ]
}

@test "E2E workflow installs only Chromium headless shell" {
  workflow="$WORKFLOW_FILE"

  run grep -F \
    "yarn playwright install --with-deps --only-shell chromium" \
    "$workflow"

  [ "$status" -eq 0 ]
}

@test "E2E workflow declares an optional publish-metrics input that defaults to false" {
  run ruby -ryaml -e '
    inputs = YAML.load_file(ARGV.fetch(0)).fetch(true).fetch("workflow_call").fetch("inputs")
    input = inputs["publish-metrics"]
    abort "publish-metrics input must exist" unless input
    abort "publish-metrics must be a boolean" unless input.fetch("type") == "boolean"
    abort "publish-metrics must be optional" unless input.fetch("required") == false
    abort "publish-metrics must default to false" unless input.fetch("default") == false
    abort "publish-metrics must be described" unless input["description"].to_s.length.positive?
  ' "$WORKFLOW_FILE"

  [ "$status" -eq 0 ]
}

@test "E2E workflow resolves the production account" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("test").fetch("steps")
    script = steps.map { |step| step["run"].to_s }.find { |run| run.include?("ACCOUNT_ID=") }
    abort "Account resolution step must exist" unless script
    abort "Development must resolve its account" unless script.include?(%q{ACCOUNT_ID="844815912454"})
    abort "Staging must resolve its account" unless script.include?(%q{ACCOUNT_ID="451934005581"})
    abort "Production must resolve its account" unless script.include?(%q{ACCOUNT_ID="382373577178"})
    abort "Account id must reach later steps" unless script.include?("ACCOUNT_ID=${ACCOUNT_ID}")
  ' "$WORKFLOW_FILE"

  [ "$status" -eq 0 ]
}

@test "E2E workflow publishes metrics only when the caller opts in" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("test").fetch("steps")
    script = steps.map { |step| step["run"].to_s }.find { |run| run.include?("PUBLISH_METRICS") }
    abort "Metrics gate must exist" unless script
    gate = %q{if [ "${{ inputs.publish-metrics }}" = "true" ]; then}
    abort "Metrics must be gated on the publish-metrics input" unless script.include?(gate)
  ' "$WORKFLOW_FILE"

  [ "$status" -eq 0 ]
}

@test "production runs assume the AWS role only when the caller opts into metrics" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("test").fetch("steps")
    credentials = steps.find { |step| step.fetch("uses", "").start_with?("aws-actions/configure-aws-credentials@") }
    abort "Credentials step must exist" unless credentials
    condition = credentials.fetch("if")
    quote = "\x27"
    abort "An unresolved account must skip the credentials step" unless condition.include?("env.ACCOUNT_ID != #{quote}#{quote}")
    abort "Production must opt in before it assumes the role" unless condition.include?("inputs.publish-metrics")
    abort "Production must be the only environment that opts in" unless condition.include?("inputs.test-environment != #{quote}production#{quote}")
  ' "$WORKFLOW_FILE"

  [ "$status" -eq 0 ]
}
