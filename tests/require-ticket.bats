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
  work_dir="$(mktemp -d)"

  export HAS_APP_DIR=true
  export TICKET_PREFIXES="HMRC|AI|HOTT"
  export HAS_NO_TICKET_LABEL=false
  export PR_BODY_FILE="${work_dir}/body.txt"
  export PR_AUTHOR_FILE="${work_dir}/author.txt"
  export CHANGED_FILES_FILE="${work_dir}/files.txt"
  set_author alice
  set_files "app/models/a.rb"
  set_body ""
}

teardown() {
  rm -rf "$check_script" "$work_dir"
}

set_body() { printf '%s' "$1" > "$PR_BODY_FILE"; }
set_author() { printf '%s\n' "$1" > "$PR_AUTHOR_FILE"; }
set_files() { printf '%s\n' "$1" > "$CHANGED_FILES_FILE"; }

@test "passes when an app change names a ticket" {
  set_body $'## Ticket:\nHMRC-2818'
  run bash "$check_script"
  [ "$status" -eq 0 ]
}

@test "accepts the AI prefix" {
  set_body "[AI-1498] thing"
  run bash "$check_script"
  [ "$status" -eq 0 ]
}

@test "fails when an app change has no ticket" {
  set_body "no ticket here"
  run bash "$check_script"
  [ "$status" -eq 1 ]
  assert_contains "$output" "has no Jira ticket"
}

@test "fails on an empty description" {
  run bash "$check_script"
  [ "$status" -eq 1 ]
}

@test "ignores the template placeholder comment" {
  set_body $'## Ticket:\n<!-- Link to the Jira ticket, e.g. HMRC-1234 -->'
  run bash "$check_script"
  [ "$status" -eq 1 ]
}

@test "ignores a ticket that is only inside a comment" {
  set_body "<!-- HMRC-1 -->"
  run bash "$check_script"
  [ "$status" -eq 1 ]
}

@test "rejects N/A, unknown prefixes and lowercase keys" {
  for body in "N/A" "ABC-123" "hmrc-123"; do
    set_body "$body"
  run bash "$check_script"
    [ "$status" -eq 1 ]
  done
}

@test "exempts Dependabot" {
  set_author "dependabot[bot]"
  run bash "$check_script"
  [ "$status" -eq 0 ]
  assert_contains "$output" "Dependabot"
}

@test "exempts the no-ticket label" {
  HAS_NO_TICKET_LABEL=true run bash "$check_script"
  [ "$status" -eq 0 ]
}


@test "exempts changes that do not touch app/" {
  set_files $'Gemfile\nGemfile.lock\ndocs/app/readme.md'
  run bash "$check_script"
  [ "$status" -eq 0 ]
}

@test "fails when app/ is one of several changed paths" {
  set_files $'Gemfile\napp/x.rb'
  run bash "$check_script"
  [ "$status" -eq 1 ]
}

@test "exempts a repository with no app/ folder" {
  HAS_APP_DIR=false run bash "$check_script"
  [ "$status" -eq 0 ]
  assert_contains "$output" "no app/ folder"
}

@test "fails when a file is moved out of app/" {
  # The files API lists the old path of a rename on its own line.
  set_files $'lib/a.rb\napp/models/a.rb'
  run bash "$check_script"
  [ "$status" -eq 1 ]
}
