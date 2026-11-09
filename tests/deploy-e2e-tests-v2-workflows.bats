#!/usr/bin/env bats

load test_helper

setup() {
  export WORKFLOW_FILE="$repo_root/.github/workflows/deploy-ecs-v2.yml"
  export WORKFLOW_FILE_MULTI="$repo_root/.github/workflows/deploy-multi-ecs-v2.yml"
}

@test "deployment workflows gate and forward projects to one E2E job" {
  run ruby -ryaml -e '
    ARGV.each do |path|
      workflow = YAML.load_file(path)
      contract = workflow.fetch(true).fetch("workflow_call")
      inputs = contract.fetch("inputs")
      input = inputs.fetch("test-projects")
      abort "#{path}: projects contract changed" unless input.fetch("default") == "api,frontend" && input.fetch("type") == "string" && input.fetch("required") == false
      passwordless = inputs.fetch("skip-passwordless")
      abort "#{path}: passwordless contract changed" unless passwordless.fetch("default") == true && passwordless.fetch("type") == "boolean" && passwordless.fetch("required") == false
      abort "#{path}: obsolete flavour input" if inputs.key?("test-flavour")
      %w[non_admin_bypass_password admin_bypass_password].each do |secret|
        abort "#{path}: obsolete FPO secret" if contract.fetch("secrets").key?(secret)
      end
      jobs = workflow.fetch("jobs")
      e2e = jobs.fetch("e2e-test")
      quote = "\x27"
      expected_gate = path.end_with?("deploy-multi-ecs-v2.yml") ? "${{ !cancelled() && needs.deploy-all.result == #{quote}success#{quote} && inputs.test-projects != #{quote}#{quote} }}" : "${{ inputs.test-projects != #{quote}#{quote} }}"
      abort "#{path}: missing selection gate" unless e2e.fetch("if") == expected_gate
      abort "#{path}: wrong E2E workflow" unless e2e.fetch("uses") == "trade-tariff/trade-tariff-tools/.github/workflows/e2e-tests-v2.yml@main"
      abort "#{path}: projects not forwarded" unless e2e.dig("with", "projects") == "${{ inputs.test-projects }}"
      abort "#{path}: passwordless preference not forwarded" unless e2e.dig("with", "skip-passwordless") == "${{ inputs.skip-passwordless }}"
      abort "#{path}: environment not forwarded" unless e2e.dig("with", "test-environment") == "${{ inputs.environment }}"
      abort "#{path}: password not forwarded" unless e2e.dig("secrets", "basic_password") == "${{ secrets.basic-password }}"
      abort "#{path}: WAF token not forwarded" unless e2e.dig("secrets", "waf_bypass_token") == "${{ secrets.waf_bypass_token }}"
      jobs.each do |id, job|
        Array(job["needs"]).each { |need| abort "#{path}: #{id} needs missing job #{need}" unless jobs.key?(need) }
      end
      references = File.read(path, encoding: "UTF-8").scan(/needs\.([a-zA-Z0-9_-]+)\./).flatten
      references.each { |id| abort "#{path}: reference to missing job #{id}" unless jobs.key?(id) }
    end
  ' "$WORKFLOW_FILE" "$WORKFLOW_FILE_MULTI"

  [ "$status" -eq 0 ] || fail "$output"
}

@test "single-app checkout inputs reach Bash through the environment" {
  run ruby -ryaml -e '
    workflow = YAML.load_file(ARGV.fetch(0))
    step = workflow.fetch("jobs").fetch("configure").fetch("steps").find { |item| item["id"] == "actual-ref" }
    abort "Checkout values must be passed through env" unless step.fetch("env") == {
      "CHECKOUT_REPO" => "${{ inputs.checkout-repo }}",
      "CHECKOUT_REF" => "${{ inputs.checkout-ref }}",
      "DEFAULT_REPOSITORY" => "${{ github.repository }}",
      "DEFAULT_REF" => "${{ github.event.workflow_run.head_sha || github.event.pull_request.head.sha || github.sha }}"
    }
    abort "Checkout values must not be interpolated into Bash" if step.fetch("run").include?("${{")
    abort "Checkout ref must be quoted in Bash" unless step.fetch("run").include?(%q{"$CHECKOUT_REF"})
  ' "$WORKFLOW_FILE"

  [ "$status" -eq 0 ] || fail "$output"
}

@test "multi-app service names reach jq through the environment" {
  run ruby -ryaml -e '
    workflow = YAML.load_file(ARGV.fetch(0))
    step = workflow.fetch("jobs").fetch("start-all").fetch("steps").find { |item| item["id"] == "parse-service-names" }
    abort "Service name JSON must be passed through env" unless step.dig("env", "SERVICE_NAMES_JSON") == "${{ toJson(matrix.app.service-names) }}"
    abort "Service name JSON must not be interpolated into Bash" if step.fetch("run").include?("${{")
    abort "Service names must be parsed from the quoted environment value" unless step.fetch("run").include?(%q{"$SERVICE_NAMES_JSON"})
  ' "$WORKFLOW_FILE_MULTI"

  [ "$status" -eq 0 ] || fail "$output"
}

@test "single-app deployment uses the E2E result for rollback and notification" {
  run ruby -ryaml -e '
    jobs = YAML.load_file(ARGV.fetch(0)).fetch("jobs")
    abort "E2E must follow deployment" unless jobs.dig("e2e-test", "needs") == "deploy"
    rollback = jobs.fetch("rollback")
    quote = "\x27"
    condition = rollback.fetch("if")
    [
      "always()", "needs.deploy.result == #{quote}success#{quote}",
      "needs.e2e-test.result == #{quote}failure#{quote}",
      "needs.configure.outputs.previous_docker_tag != #{quote}#{quote}",
      "inputs.environment == #{quote}staging#{quote}",
      "inputs.environment == #{quote}production#{quote}"
    ].each { |gate| abort "Rollback gate missing: #{gate}" unless condition.include?(gate) }
    %w[rollback notify].each do |id|
      abort "#{id} must await E2E" unless jobs.fetch(id).fetch("needs").include?("e2e-test")
    end
    step = jobs.fetch("notify").fetch("steps").find { |item| item["id"] == "result" }
    abort "Result script must receive selected projects" unless step.dig("env", "TEST_PROJECTS") == "${{ inputs.test-projects }}"
    abort "Result script must receive the E2E result" unless step.dig("env", "E2E_TEST_RESULT") == "${{ needs.e2e-test.result }}"
    abort "Result script call missing" unless step.fetch("run").include?(".trade-tariff-tools/scripts/deploy-result-v2.sh")
  ' "$WORKFLOW_FILE"

  [ "$status" -eq 0 ] || fail "$output"
}

@test "single-app service matching validates app names and quotes prefixes" {
  run ruby -ryaml -e '
    workflow = YAML.load_file(ARGV.fetch(0))
    config = workflow.fetch("jobs").fetch("configure").fetch("steps").find { |item| item["id"] == "config" }
    expected_env = {
      "APP_NAME" => "${{ inputs.app-name }}",
      "CLUSTER" => "${{ steps.environment-config.outputs.cluster }}",
      "ECR_URL" => "${{ steps.environment-config.outputs.ecr-url }}",
      "IAM_ROLE_ARN" => "${{ steps.environment-config.outputs.deploy-role-arn }}",
      "SLACK_CHANNEL" => "${{ steps.environment-config.outputs.slack-channel }}"
    }
    abort "Config values must pass through env" unless config.fetch("env") == expected_env
    source = config.fetch("run")
    abort "Config values must not be inserted into Bash source" if source.include?("${{")
    abort "app-name must be a nonempty single token" unless source.include?(%q{[[ -z "$APP_NAME" || -z "$REPO_NAME" || "$APP_NAME" == *[[:space:]]* ]]})
    abort "service prefixes must be quoted" unless source.include?(%q{[[ "$SERVICE_NAME" == "$APP_NAME"* || "$SERVICE_NAME" == "$REPO_NAME"* ]]})
    abort "ruby-version must be checked for control characters" unless source.include?(%q{if [[ "${!OUTPUT_NAME}" == *[[:cntrl:]]* ]]; then})
    quote = "\x27"
    %w[ecr_url iam_role_arn previous_docker_tag ruby_version slack_channel docker_tag].each do |name|
      abort "#{name} must use a fixed printf format" unless source.include?("printf #{quote}#{name}=%s\\n#{quote}")
    end
  ' "$WORKFLOW_FILE"

  [ "$status" -eq 0 ] || fail "$output"
}

@test "single-app notification checks the result through a quoted environment value" {
  run ruby -ryaml -e '
    workflow = YAML.load_file(ARGV.fetch(0))
    steps = workflow.fetch("jobs").fetch("notify").fetch("steps")
    step = steps.last
    abort "Result must pass through env" unless step.fetch("env") == { "RESULT" => "${{ steps.result.outputs.result }}" }
    abort "Result must not be inserted into Bash source" if step.fetch("run").include?("${{")
    abort "Result must be compared as quoted data" unless step.fetch("run") == %q{if [[ "$RESULT" != "success" ]]; then exit 1; fi}
  ' "$WORKFLOW_FILE"

  [ "$status" -eq 0 ] || fail "$output"
}

@test "multi-app deployment runs E2E once after the matrix and preserves result precedence" {
  run ruby -ryaml -e '
    jobs = YAML.load_file(ARGV.fetch(0)).fetch("jobs")
    abort "Per-app E2E must be disabled explicitly" unless jobs.dig("deploy-all", "with", "test-projects") == ""
    abort "Deployment must wait for startup" unless jobs.dig("deploy-all", "needs") == "start-all" && jobs.dig("deploy-all", "if").include?("skipped")
    abort "Aggregate E2E must follow the matrix" unless jobs.dig("e2e-test", "needs") == "deploy-all"
    notify = jobs.fetch("notify-completion")
    abort "Notification must await startup, deployment and E2E" unless notify.fetch("needs").sort == %w[deploy-all e2e-test start-all]
    step = notify.fetch("steps").find { |item| item["id"] == "result" }
    expression = step.fetch("env").fetch("RESULT").delete_prefix("${{").delete_suffix("}}").strip
    # These expressions use the subset shared by Ruby and GitHub: string
    # comparisons and short-circuit boolean operators with nonempty job results.
    cases = [
      ["skipped", "success", "api,frontend", "success", "success"],
      ["skipped", "success", "admin", "failure", "failure"],
      ["skipped", "success", "", "skipped", "success"],
      ["skipped", "success", "myott", "skipped", "skipped"],
      ["skipped", "success", "dev-hub", "cancelled", "cancelled"],
      ["skipped", "failure", "api", "skipped", "failure"],
      ["skipped", "cancelled", "api", "skipped", "cancelled"],
      ["skipped", "skipped", "", "skipped", "skipped"],
      ["failure", "skipped", "api", "skipped", "failure"],
      ["cancelled", "skipped", "api", "skipped", "cancelled"],
      ["success", "success", "api", "success", "success"]
    ]
    cases.each do |startup, deploy, projects, e2e, expected|
      source = expression.gsub("needs.start-all.result", startup.inspect)
        .gsub("needs.deploy-all.result", deploy.inspect)
        .gsub("inputs.test-projects", projects.inspect)
        .gsub("needs.e2e-test.result", e2e.inspect)
      actual = eval(source)
      abort "Wrong notification result for #{[startup, deploy, projects, e2e]}: #{actual}" unless actual == expected
    end
    abort "Result must pass through env" unless step.fetch("run") == %q{echo "result=$RESULT" >> "$GITHUB_OUTPUT"}
  ' "$WORKFLOW_FILE_MULTI"

  [ "$status" -eq 0 ] || fail "$output"
}
