#!/usr/bin/env bats

load test_helper

# GitHub cannot load an action or workflow that is not valid YAML. The other
# tests read these files with grep, so they pass even when the file is broken.
# A broken action file fails every workflow that uses it.

parse_error_for() {
  ruby -ryaml -e 'begin; YAML.load_file(ARGV.fetch(0)); rescue Psych::Exception => error; puts error.message; exit 1; end' "$1"
}

@test "every composite action file is valid YAML" {
  local file
  for file in "$repo_root"/.github/actions/*/action.yml; do
    run parse_error_for "$file"
    [ "$status" -eq 0 ] || fail "${file#"$repo_root"/} is not valid YAML: $output"
  done
}

@test "every workflow file is valid YAML" {
  local file
  for file in "$repo_root"/.github/workflows/*.yml; do
    run parse_error_for "$file"
    [ "$status" -eq 0 ] || fail "${file#"$repo_root"/} is not valid YAML: $output"
  done
}
