#!/usr/bin/env bats

load test_helper

@test "axxy workflow passes an optional WAF bypass token only to Playwright" {
  run ruby -ryaml -e '
    workflow = YAML.load_file(ARGV.fetch(0))
    secrets = workflow.fetch(true).fetch("workflow_call").fetch("secrets")
    abort "WAF bypass token must be optional" unless secrets.dig("waf_bypass_token", "required") == false

    job = workflow.fetch("jobs").fetch("test")
    steps = job.fetch("steps")
    test_step = steps.find { |step| step["run"] == "yarn run playwright test --workers 1" }
    token = "${{ secrets.waf_bypass_token }}"
    abort "Playwright must receive the WAF bypass token" unless test_step.dig("env", "WAF_BYPASS_TOKEN") == token

    test_step.fetch("env").delete("WAF_BYPASS_TOKEN")
    remaining_workflow = YAML.dump(workflow)
    abort "WAF bypass token must stay scoped to Playwright" if remaining_workflow.include?(token) || remaining_workflow.include?("WAF_BYPASS_TOKEN")
  ' "$repo_root/.github/workflows/axxy-tests.yml"

  [ "$status" -eq 0 ]
}

@test "axxy workflow retains failed test diagnostics without Playwright traces" {
  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("test").fetch("steps")
    upload = steps.find { |step| step.fetch("uses", "").start_with?("actions/upload-artifact@") }
    abort "Failed test diagnostics must be uploaded" unless upload
    abort "Diagnostics must survive test failure" unless upload["if"] == "failure()"
    abort "Artifact action must use an immutable commit" unless upload.fetch("uses").match?(/@[0-9a-f]{40}\z/)
    abort "Diagnostics must expire after seven days" unless upload.fetch("with")["retention-days"] == 7

    paths = upload.fetch("with").fetch("path").lines.map(&:strip)
    abort "Only reports and test diagnostics should be retained" unless paths == [
      "dist/accessibility-report.html",
      "test-results",
      "!test-results/**/trace.zip",
    ]
  ' "$repo_root/.github/workflows/axxy-tests.yml"

  [ "$status" -eq 0 ]
}

@test "ci runs when the axxy workflow changes" {
  run ruby -ryaml -e '
    paths = YAML.load_file(ARGV.fetch(0)).fetch(true).fetch("pull_request").fetch("paths")
    abort "CI must cover accessibility workflow changes" unless paths.include?(".github/workflows/axxy-tests.yml")
  ' "$repo_root/.github/workflows/ci.yml"

  [ "$status" -eq 0 ]
}
