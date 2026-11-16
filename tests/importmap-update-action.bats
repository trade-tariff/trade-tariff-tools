#!/usr/bin/env bats

load test_helper

@test "importmap-update action checks out the caller repository with the update token" {
  action="$repo_root/.github/actions/importmap-update/action.yml"

  run grep -F "uses: actions/checkout@v7.0.0" "$action"
  [ "$status" -eq 0 ]

  run grep -F 'token: ${{ inputs.github-token }}' "$action"
  [ "$status" -eq 0 ]
}

@test "importmap-update action sets up Ruby before running the updater" {
  action="$repo_root/.github/actions/importmap-update/action.yml"

  run ruby -ryaml -e '
    steps = YAML.load_file(ARGV.fetch(0)).fetch("runs").fetch("steps")
    setup = steps.find { |step| step.fetch("uses", "").start_with?("ruby/setup-ruby@") }
    version = setup.fetch("uses").split("@v").last
    abort "Ruby setup must support Ubuntu 26.04" unless Gem::Version.new(version) >= Gem::Version.new("1.336.0")
  ' "$action"
  [ "$status" -eq 0 ]

  run grep -F 'bundler-cache: ${{ inputs.bundler-cache }}' "$action"
  [ "$status" -eq 0 ]
}

@test "Dependabot covers workflows and every composite action directory" {
  run ruby -ryaml -e '
    root = ARGV.fetch(0)
    updates = YAML.load_file(File.join(root, ".github/dependabot.yml")).fetch("updates")
    directories = updates.select { |update| update.fetch("package-ecosystem") == "github-actions" }
                         .flat_map { |update| update.fetch("directories") { [update.fetch("directory")] } }
    abort "Workflow updates must stay enabled" unless directories.include?("/")
    Dir.glob(File.join(root, ".github/actions/*/action.{yml,yaml}")).each do |action|
      directory = File.dirname(action).delete_prefix(root)
      abort "Dependabot does not cover #{directory}" unless directories.any? { |pattern| File.fnmatch?(pattern, directory, File::FNM_PATHNAME) }
    end
  ' "$repo_root"

  [ "$status" -eq 0 ]
}

@test "importmap-update action delegates to thoughtbot importmap-update" {
  action="$repo_root/.github/actions/importmap-update/action.yml"

  run grep -F "uses: thoughtbot/importmap-update@v1.0.0-alpha3" "$action"
  [ "$status" -eq 0 ]

  run grep -F 'github-token: ${{ inputs.github-token }}' "$action"
  [ "$status" -eq 0 ]

  run grep -F 'dry-run: ${{ inputs.dry-run }}' "$action"
  [ "$status" -eq 0 ]
}
