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
  read_script="$(mktemp)"
  ruby -ryaml -e '
    steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch("require-ticket").fetch("steps")
    puts steps.find { |step| step["name"] == "Read the current pull request" }.fetch("run")
  ' "$workflow" > "$read_script"
  work_dir="$(mktemp -d)"

  export HAS_APP_DIR=true
  export TICKET_PREFIXES="HMRC|AI|HOTT"
  export HAS_NO_TICKET_LABEL=false
  export FILE_LIST_COMPLETE=true
  export PR_BODY_FILE="${work_dir}/body.txt"
  export PR_AUTHOR_FILE="${work_dir}/author.txt"
  export CHANGED_FILES_FILE="${work_dir}/files.txt"
  set_author alice
  set_files "app/models/a.rb"
  set_body ""
}

teardown() {
  rm -rf "$check_script" "$read_script" "$work_dir"
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

@test "runs in the merge queue and skips the checks there" {
  run ruby -ryaml -e '
    workflow = YAML.load_file(ARGV[0])
    triggers = workflow["on"] || workflow[true]
    abort "no merge_group trigger" unless triggers.key?("merge_group")
    steps = workflow.fetch("jobs").fetch("require-ticket").fetch("steps")
    guarded = steps.select { |step| step["if"] == "github.event_name == \u0027pull_request\u0027" }
    abort "PR steps must skip merge_group" unless guarded.size == 2
  ' "$workflow"
  [ "$status" -eq 0 ]
}

@test "passes a truncated file list when the description has a ticket" {
  FILE_LIST_COMPLETE=false
  set_body "HMRC-1"
  run bash "$check_script"
  [ "$status" -eq 0 ]
}

@test "passes a truncated file list when the PR has the no-ticket label" {
  FILE_LIST_COMPLETE=false HAS_NO_TICKET_LABEL=true run bash "$check_script"
  [ "$status" -eq 0 ]
}

@test "fails closed on a truncated file list with no ticket" {
  FILE_LIST_COMPLETE=false
  set_files "docs/readme.md"
  run bash "$check_script"
  [ "$status" -eq 1 ]
  assert_contains "$output" "fewer files than the PR changed"
}

# --- The "Read the current pull request" step, run against a stubbed gh ---

# Writes a gh stub that answers from fixture files in $work_dir:
#   fixture-pr.json and fixture-files.json, and CONTENTS_MODE (ok, 404 or 500) for the app/ listing.
stub_gh() {
  mkdir -p "${work_dir}/bin"
  cat > "${work_dir}/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"/contents/app"*)
    case "$CONTENTS_MODE" in
      ok) echo "[]" ;;
      404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
      *) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
    esac ;;
  *"/files"*)
    expression="${args##*--jq }"
    jq -c "$expression" "${FIXTURES}/fixture-files.json" ;;
  *"/pulls/"*) cat "${FIXTURES}/fixture-pr.json" ;;
  *) echo "unexpected gh call: $args" >&2; exit 2 ;;
esac
STUB
  chmod +x "${work_dir}/bin/gh"
}

run_read_step() {
  stub_gh
  export FIXTURES="$work_dir" CONTENTS_MODE="${CONTENTS_MODE:-ok}"
  export GH_TOKEN=x REPOSITORY=trade-tariff/example PR_NUMBER=7 BASE_SHA=abc123
  export RUNNER_TEMP="$work_dir" GITHUB_OUTPUT="${work_dir}/output.txt"
  : > "$GITHUB_OUTPUT"
  PATH="${work_dir}/bin:${PATH}" run bash "$read_script"
}

@test "read step: lists both paths of a rename and a complete list" {
  echo '{"body":"HMRC-1","user":{"login":"alice"},"labels":[],"changed_files":2}' > "${work_dir}/fixture-pr.json"
  echo '[{"filename":"lib/a.rb","previous_filename":"app/a.rb"},{"filename":"x.rb"}]' > "${work_dir}/fixture-files.json"
  run_read_step
  [ "$status" -eq 0 ]
  assert_contains "$(cat "${work_dir}/pr-files.txt")" "app/a.rb"
  assert_contains "$(cat "${work_dir}/pr-files.txt")" "lib/a.rb"
  assert_contains "$(cat "$GITHUB_OUTPUT")" "file_list_complete=true"
  assert_contains "$(cat "$GITHUB_OUTPUT")" "has_app_dir=true"
}

@test "read step: marks the list incomplete when fewer files come back" {
  echo '{"body":"","user":{"login":"alice"},"labels":[],"changed_files":3001}' > "${work_dir}/fixture-pr.json"
  echo '[{"filename":"x.rb"}]' > "${work_dir}/fixture-files.json"
  run_read_step
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$GITHUB_OUTPUT")" "file_list_complete=false"
}

@test "read step: matches the no-ticket label by whole name" {
  echo '{"body":null,"user":{"login":"alice"},"labels":[{"name":"review,no-ticket"}],"changed_files":1}' > "${work_dir}/fixture-pr.json"
  echo '[{"filename":"x.rb"}]' > "${work_dir}/fixture-files.json"
  run_read_step
  assert_contains "$(cat "$GITHUB_OUTPUT")" "has_no_ticket_label=false"

  echo '{"body":null,"user":{"login":"alice"},"labels":[{"name":"no-ticket"}],"changed_files":1}' > "${work_dir}/fixture-pr.json"
  run_read_step
  assert_contains "$(cat "$GITHUB_OUTPUT")" "has_no_ticket_label=true"
}

@test "read step: a null description becomes blank text" {
  echo '{"body":null,"user":{"login":"alice"},"labels":[],"changed_files":1}' > "${work_dir}/fixture-pr.json"
  echo '[{"filename":"x.rb"}]' > "${work_dir}/fixture-files.json"
  run_read_step
  [ "$status" -eq 0 ]
  [ -z "$(cat "${work_dir}/pr-body.txt")" ]
}

@test "read step: a 404 on app/ means no app folder" {
  echo '{"body":"","user":{"login":"alice"},"labels":[],"changed_files":1}' > "${work_dir}/fixture-pr.json"
  echo '[{"filename":"x.rb"}]' > "${work_dir}/fixture-files.json"
  CONTENTS_MODE=404 run_read_step
  [ "$status" -eq 0 ]
  assert_contains "$(cat "$GITHUB_OUTPUT")" "has_app_dir=false"
}

@test "read step: any other API error fails the job" {
  echo '{"body":"","user":{"login":"alice"},"labels":[],"changed_files":1}' > "${work_dir}/fixture-pr.json"
  echo '[{"filename":"x.rb"}]' > "${work_dir}/fixture-files.json"
  CONTENTS_MODE=500 run_read_step
  [ "$status" -eq 1 ]
  assert_contains "$output" "Could not check for an app/ folder"
}
