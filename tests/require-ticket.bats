#!/usr/bin/env bats

load test_helper

# The check script lives inline in the workflow, because an org-required
# workflow cannot check out this repository. These tests extract it and run it.

setup() {
  workflow="${BATS_TEST_DIRNAME}/../.github/workflows/require-ticket.yml"
  [[ -f "$workflow" ]] || fail "missing ${workflow}"
  check_script="$(mktemp)"
  ruby -ryaml -e '
    steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch("require-ticket").fetch("steps")
    puts steps.find { |step| step["name"] == "Check for a Jira ticket" }.fetch("run")
  ' "$workflow" > "$check_script"

  export HAS_APP_DIR=true
  export TICKET_PREFIXES="HMRC|AI|HOTT"
  export PR_AUTHOR=alice
  export PR_LABELS=""
  export CHANGED_FILES="app/models/a.rb"
  export PR_BODY=""
}

teardown() {
  rm -f "$check_script"
}

@test "passes when an app change names a ticket" {
  PR_BODY=$'## Ticket:\nHMRC-2818' run bash "$check_script"
  [ "$status" -eq 0 ]
}

@test "accepts the AI prefix" {
  PR_BODY="[AI-1498] thing" run bash "$check_script"
  [ "$status" -eq 0 ]
}

@test "fails when an app change has no ticket" {
  PR_BODY="no ticket here" run bash "$check_script"
  [ "$status" -eq 1 ]
  assert_contains "$output" "has no Jira ticket"
}

@test "fails on an empty description" {
  run bash "$check_script"
  [ "$status" -eq 1 ]
}

@test "ignores the template placeholder comment" {
  PR_BODY=$'## Ticket:\n<!-- Link to the Jira ticket, e.g. HMRC-1234 -->' run bash "$check_script"
  [ "$status" -eq 1 ]
}

@test "ignores a ticket that is only inside a comment" {
  PR_BODY="<!-- HMRC-1 -->" run bash "$check_script"
  [ "$status" -eq 1 ]
}

@test "rejects N/A, unknown prefixes and lowercase keys" {
  for body in "N/A" "ABC-123" "hmrc-123"; do
    PR_BODY="$body" run bash "$check_script"
    [ "$status" -eq 1 ]
  done
}

@test "exempts Dependabot" {
  PR_AUTHOR="dependabot[bot]" run bash "$check_script"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Dependabot"
}

@test "exempts the no-ticket label" {
  PR_LABELS="bug,no-ticket" run bash "$check_script"
  [ "$status" -eq 0 ]
}

@test "does not exempt a label that only contains no-ticket" {
  PR_LABELS="no-ticket-needed" run bash "$check_script"
  [ "$status" -eq 1 ]
}

@test "exempts changes that do not touch app/" {
  CHANGED_FILES=$'Gemfile\nGemfile.lock\ndocs/app/readme.md' run bash "$check_script"
  [ "$status" -eq 0 ]
}

@test "fails when app/ is one of several changed paths" {
  CHANGED_FILES=$'Gemfile\napp/x.rb' run bash "$check_script"
  [ "$status" -eq 1 ]
}

@test "exempts a repository with no app/ folder" {
  HAS_APP_DIR=false run bash "$check_script"
  [ "$status" -eq 0 ]
  assert_contains "$output" "no app/ folder"
}
