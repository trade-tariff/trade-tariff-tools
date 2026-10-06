#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  export TEST_CAPTURE_DIR="$tmpdir"
  setup_stub_path
  script="$repo_root/.github/actions/start-services/scale-services.sh"

  cat > "$stub_bin/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_CAPTURE_DIR/aws-commands.txt"

service=""
previous=""
for arg in "$@"; do
  if [[ "$previous" == "--services" || "$previous" == "--service" ]]; then
    service="$arg"
  fi
  previous="$arg"
done

if [[ "$1" == "ecs" && "$2" == "describe-services" ]]; then
  if [[ "$service" == missing-* ]]; then
    printf '\n'
  else
    printf '%s\n' "$service"
  fi
  exit 0
fi

if [[ "$1" == "ecs" && "$2" == "update-service" ]]; then
  if [[ "$service" == broken-* ]]; then
    exit 1
  fi
  printf '%s\n' "$service"
  exit 0
fi

echo "unexpected aws command: $*" >&2
exit 1
STUB
  chmod +x "$stub_bin/aws"
}

teardown() {
  rm -rf "$tmpdir"
}

@test "starts every service with the desired count" {
  run "$script" --cluster trade-tariff-cluster --region eu-west-2 --desired-count 2 --verb start frontend backend

  [ "$status" -eq 0 ]
  assert_contains "$output" "::group::Starting service: frontend"
  assert_contains "$output" "::notice::✓ Started frontend (desired count: 2)"
  assert_contains "$output" "::notice::✓ Started backend (desired count: 2)"
  assert_contains "$output" "::notice::✓ Successfully started 2 service(s):"
  assert_contains "$output" "::notice::All services started successfully!"
  commands="$(cat "$tmpdir/aws-commands.txt")"
  assert_contains "$commands" "ecs update-service --cluster trade-tariff-cluster --service frontend --desired-count 2 --region eu-west-2"
  assert_contains "$commands" "ecs update-service --cluster trade-tariff-cluster --service backend --desired-count 2 --region eu-west-2"
}

@test "stops services with stop wording" {
  run "$script" --cluster trade-tariff-cluster --region eu-west-2 --desired-count 0 --verb stop frontend

  [ "$status" -eq 0 ]
  assert_contains "$output" "::group::Stopping service: frontend"
  assert_contains "$output" "::notice::✓ Stopped frontend (desired count: 0)"
  assert_contains "$output" "::notice::✓ Successfully stopped 1 service(s):"
  assert_contains "$output" "::notice::All services stopped successfully!"
  assert_contains "$(cat "$tmpdir/aws-commands.txt")" "--desired-count 0"
}

@test "reports a missing service and continues with the others" {
  run "$script" --cluster trade-tariff-cluster --region eu-west-2 --desired-count 1 --verb start missing-api frontend

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::Service 'missing-api' does not exist or is not active in cluster 'trade-tariff-cluster'"
  assert_contains "$output" "::notice::✓ Started frontend (desired count: 1)"
  assert_contains "$output" "::error::✗ Failed to start 1 service(s):"
  assert_contains "$output" "::error::  - missing-api (not found)"
  assert_not_contains "$(cat "$tmpdir/aws-commands.txt")" "update-service --cluster trade-tariff-cluster --service missing-api"
}

@test "reports a failed update" {
  run "$script" --cluster trade-tariff-cluster --region eu-west-2 --desired-count 1 --verb stop broken-api

  [ "$status" -eq 1 ]
  assert_contains "$output" "::error::✗ Failed to stop broken-api"
  assert_contains "$output" "::error::✗ Failed to stop 1 service(s):"
  assert_contains "$output" "::error::  - broken-api"
}

@test "prints help" {
  run "$script" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: scale-services.sh"
}

@test "does nothing and succeeds with no service names, like the old loop" {
  run "$script" --cluster trade-tariff-cluster --region eu-west-2 --desired-count 1 --verb start

  [ "$status" -eq 0 ]
  assert_contains "$output" "::notice::All services started successfully!"
  [ ! -f "$tmpdir/aws-commands.txt" ]
}

@test "does nothing and succeeds with no service names under the system bash" {
  # /bin/bash is bash 3.2 on macOS. It treats an empty array as unbound under nounset.
  run /bin/bash "$script" --cluster trade-tariff-cluster --region eu-west-2 --desired-count 1 --verb start

  [ "$status" -eq 0 ]
  assert_contains "$output" "::notice::All services started successfully!"
  [ ! -f "$tmpdir/aws-commands.txt" ]
}

@test "rejects a desired count that is not a non-negative integer" {
  run "$script" --cluster trade-tariff-cluster --region eu-west-2 --desired-count abc --verb start frontend

  [ "$status" -eq 2 ]
  assert_contains "$output" "Invalid --desired-count: abc (expected a non-negative integer)"
  [ ! -f "$tmpdir/aws-commands.txt" ]
}

@test "rejects a missing flag value" {
  run "$script" --cluster trade-tariff-cluster --region eu-west-2 --verb start frontend

  [ "$status" -eq 2 ]
  assert_contains "$output" "Missing required argument: --desired-count"
}

@test "rejects an unknown verb" {
  run "$script" --cluster trade-tariff-cluster --region eu-west-2 --desired-count 1 --verb restart frontend

  [ "$status" -eq 2 ]
  assert_contains "$output" "Invalid --verb: restart (expected start or stop)"
}

@test "start-services action delegates to scale-services.sh" {
  action="$repo_root/.github/actions/start-services/action.yml"

  run grep -F '"${{ github.action_path }}/scale-services.sh"' "$action"
  [ "$status" -eq 0 ]
  run grep -F -- "--verb start" "$action"
  [ "$status" -eq 0 ]
  run grep -F 'SERVICE_NAMES: ${{ inputs.service-names }}' "$action"
  [ "$status" -eq 0 ]
  run grep -F '$SERVICE_NAMES' "$action"
  [ "$status" -eq 0 ]
  run grep -F '"$SERVICE_NAMES"' "$action"
  [ "$status" -ne 0 ]
  run grep -F 'for SERVICE_NAME in' "$action"
  [ "$status" -ne 0 ]
}

@test "stop-services action delegates to the start-services script" {
  action="$repo_root/.github/actions/stop-services/action.yml"

  run grep -F '"${{ github.action_path }}/../start-services/scale-services.sh"' "$action"
  [ "$status" -eq 0 ]
  run grep -F -- "--desired-count 0" "$action"
  [ "$status" -eq 0 ]
  run grep -F -- "--verb stop" "$action"
  [ "$status" -eq 0 ]
  run grep -F 'SERVICE_NAMES: ${{ inputs.service-names }}' "$action"
  [ "$status" -eq 0 ]
  run grep -F 'for SERVICE_NAME in' "$action"
  [ "$status" -ne 0 ]
}
