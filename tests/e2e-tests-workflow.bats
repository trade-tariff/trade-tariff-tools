#!/usr/bin/env bats

load test_helper

@test "e2e workflow installs only Chromium headless shell" {
  workflow="$repo_root/.github/workflows/e2e-tests.yml"

  run grep -F \
    "yarn playwright install --with-deps --only-shell chromium" \
    "$workflow"

  [ "$status" -eq 0 ]
}

@test "e2e workflow declares an optional publish-metrics input that defaults to false" {
  run ruby -ryaml -e '
    inputs = YAML.load_file(ARGV.fetch(0)).fetch(true).fetch("workflow_call").fetch("inputs")
    input = inputs["publish-metrics"]
    abort "publish-metrics input must exist" unless input
    abort "publish-metrics must be a boolean" unless input.fetch("type") == "boolean"
    abort "publish-metrics must be optional" unless input.fetch("required") == false
    abort "publish-metrics must default to false" unless input.fetch("default") == false
    abort "publish-metrics must be described" unless input["description"].to_s.length.positive?
  ' "$repo_root/.github/workflows/e2e-tests.yml"

  [ "$status" -eq 0 ]
}

@test "e2e workflow resolves the production account" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("test").fetch("steps")
    script = steps.map { |step| step["run"].to_s }.find { |run| run.include?("ACCOUNT_ID=") }
    abort "Account resolution step must exist" unless script
    abort "Development must resolve its account" unless script.include?(%q{ACCOUNT_ID="844815912454"})
    abort "Staging must resolve its account" unless script.include?(%q{ACCOUNT_ID="451934005581"})
    abort "Production must resolve its account" unless script.include?(%q{ACCOUNT_ID="382373577178"})
    abort "Account id must reach later steps" unless script.include?("ACCOUNT_ID=${ACCOUNT_ID}")
  ' "$repo_root/.github/workflows/e2e-tests.yml"

  [ "$status" -eq 0 ]
}

@test "e2e workflow publishes metrics only when the caller opts in" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("test").fetch("steps")
    script = steps.map { |step| step["run"].to_s }.find { |run| run.include?("PUBLISH_METRICS") }
    abort "Metrics gate must exist" unless script
    gate = %q{if [ "${{ inputs.publish-metrics }}" = "true" ]; then}
    abort "Metrics must be gated on the publish-metrics input" unless script.include?(gate)
  ' "$repo_root/.github/workflows/e2e-tests.yml"

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
  ' "$repo_root/.github/workflows/e2e-tests.yml"

  [ "$status" -eq 0 ]
}

@test "ci runs when the e2e workflow changes" {
  run ruby -ryaml -e '
    paths = YAML.load_file(ARGV.fetch(0)).fetch(true).fetch("pull_request").fetch("paths")
    abort "CI must cover end-to-end workflow changes" unless paths.include?(".github/workflows/e2e-tests.yml")
  ' "$repo_root/.github/workflows/ci.yml"

  [ "$status" -eq 0 ]
}
