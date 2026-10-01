#!/usr/bin/env bats

load test_helper

# CI provides required status checks. A required check must report on every
# pull request and on every merge queue run, or the pull request cannot merge.
@test "ci runs on every pull request and in the merge queue" {
  run ruby -ryaml -e '
    triggers = YAML.load_file(ARGV.fetch(0)).fetch(true)
    abort "CI must run on pull requests" unless triggers.key?("pull_request")
    abort "CI must run in the merge queue" unless triggers.key?("merge_group")
    abort "CI must not filter pull requests by path" if triggers.fetch("pull_request").is_a?(Hash) && triggers.fetch("pull_request").key?("paths")
  ' "$repo_root/.github/workflows/ci.yml"

  [ "$status" -eq 0 ]
}
