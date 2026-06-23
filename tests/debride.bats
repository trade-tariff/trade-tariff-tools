#!/usr/bin/env bats

load test_helper

setup() {
  repo="$(mktemp -d)"
  script="${BATS_TEST_DIRNAME}/../.github/actions/debride/debride-check"
  [[ -f "$script" ]] || fail "missing ${script}"

  mkdir -p "$repo/app" "$repo/config"
  raw_output="$repo/debride-output.txt"
}

teardown() {
  rm -rf "$repo"
}

write_debride_output() {
  cat > "$raw_output" <<'EOF'
These methods MIGHT not be called:

ApplicationController
  skip_time_machine                   app/controllers/application_controller.rb:12-14 (3)

TariffSynchronizer::Mailer
  file_write_error                    app/mailers/tariff_synchronizer/mailer.rb:20-22 (3)
EOF
}

@test "passes when normalized findings match the baseline" {
  write_debride_output
  cat > "$repo/config/debride.whitelist" <<'EOF'
# Existing framework-driven findings

ApplicationController#skip_time_machine
TariffSynchronizer::Mailer#file_write_error
EOF

  cd "$repo" || return 1
  run env DEBRIDE_OUTPUT_FILE="$raw_output" bash "$script" --baseline config/debride.whitelist -- app

  [ "$status" -eq 0 ]
  assert_contains "$output" "Debride findings match config/debride.whitelist"
}

@test "fails when Debride reports a finding outside the baseline" {
  write_debride_output
  cat > "$repo/config/debride.whitelist" <<'EOF'
ApplicationController#skip_time_machine
EOF

  cd "$repo" || return 1
  run env DEBRIDE_OUTPUT_FILE="$raw_output" bash "$script" --baseline config/debride.whitelist -- app

  [ "$status" -eq 1 ]
  assert_contains "$output" "Debride reported methods not in config/debride.whitelist"
  assert_contains "$output" "TariffSynchronizer::Mailer#file_write_error"
}

@test "writes a normalized baseline" {
  write_debride_output

  cd "$repo" || return 1
  run env DEBRIDE_OUTPUT_FILE="$raw_output" bash "$script" --baseline config/debride.whitelist --update-baseline -- app

  [ "$status" -eq 0 ]
  assert_contains "$output" "Updated Debride baseline at config/debride.whitelist"
  assert_contains "$(cat "$repo/config/debride.whitelist")" "ApplicationController#skip_time_machine"
  assert_contains "$(cat "$repo/config/debride.whitelist")" "TariffSynchronizer::Mailer#file_write_error"
}

@test "handles Debride findings reported under main" {
  cat > "$raw_output" <<'EOF'
These methods MIGHT not be called:

main
  graphviz                            config.rb:53-66 (14)

Total suspect LOC: 14
EOF

  cd "$repo" || return 1
  run env DEBRIDE_OUTPUT_FILE="$raw_output" bash "$script" --baseline config/debride.whitelist --update-baseline -- config.rb

  [ "$status" -eq 0 ]
  assert_contains "$(cat "$repo/config/debride.whitelist")" "main#graphviz"
}

@test "fails clearly when the baseline is missing" {
  write_debride_output

  cd "$repo" || return 1
  run env DEBRIDE_OUTPUT_FILE="$raw_output" bash "$script" --baseline config/debride.whitelist -- app

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing Debride baseline: config/debride.whitelist"
}
