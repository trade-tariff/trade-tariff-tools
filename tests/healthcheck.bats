#!/usr/bin/env bats

load test_helper

setup() {
  tmpdir="$(mktemp -d)"
  setup_stub_path

  # Fake curl. It finds the response for a URL in $STUB_RESPONSES/<host><path>
  # and writes the files that bin/healthcheck expects. A response directory
  # holds "status", an optional "body", optional "headers" and an optional
  # "exit" code. A missing directory acts as a healthy empty 200.
  cat > "$stub_bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

output=""
headers=""
write_out=""
url=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    --write-out) write_out="$2"; shift 2 ;;
    --header)
      [[ "$2" == @* ]] && cat "${2#@}" >> "$STUB_RESPONSES/headers-sent.txt"
      printf '%s\n' "$2" >> "$STUB_RESPONSES/header-args.txt"
      shift 2
      ;;
    --max-time|--request|--data) shift 2 ;;
    --*) shift ;;
    *) url="$1"; shift ;;
  esac
done

printf '%s\n' "$url" >> "$STUB_RESPONSES/calls.txt"
dir="$STUB_RESPONSES/${url#https://}"

if [[ -f "$dir/exit" ]]; then
  echo "curl: (28) Operation timed out" >&2
  printf '000 10.000000'
  exit "$(cat "$dir/exit")"
fi

status="200"
[[ -f "$dir/status" ]] && status="$(cat "$dir/status")"
if [[ -f "$dir/body" ]]; then cp "$dir/body" "$output"; else : > "$output"; fi
if [[ -f "$dir/headers" ]]; then cp "$dir/headers" "$headers"; else : > "$headers"; fi
[[ "$write_out" == *http_code* ]] && printf '%s 0.123456' "$status"
STUB
  chmod +x "$stub_bin/curl"

  STUB_RESPONSES="$tmpdir/responses"
  mkdir -p "$STUB_RESPONSES"
  : > "$STUB_RESPONSES/calls.txt"
  export STUB_RESPONSES
  unset FPO_API_KEY FPO_API_KEY_DEVELOPMENT FPO_API_KEY_STAGING FPO_API_KEY_PRODUCTION
}

teardown() {
  rm -rf "$tmpdir"
}

stub_response() {
  local path="$1" status="$2" body="${3:-}"
  mkdir -p "$STUB_RESPONSES/$path"
  printf '%s' "$status" > "$STUB_RESPONSES/$path/status"
  [[ -n "$body" ]] && printf '%s' "$body" > "$STUB_RESPONSES/$path/body"
  return 0
}

healthy_backend='{"git_sha1":"abc1234","sidekiq":true,"postgres":true,"redis":true,"opensearch":true,"healthy":true}'
healthy_sha='{"git_sha1":"def5678"}'

stub_healthy_production() {
  stub_response www.trade-tariff.service.gov.uk/healthcheck 200 "$healthy_sha"
  stub_response www.trade-tariff.service.gov.uk/uk/api/healthcheck 200 "$healthy_backend"
  stub_response www.trade-tariff.service.gov.uk/xi/api/healthcheck 200 "$healthy_backend"
  stub_response admin.trade-tariff.service.gov.uk/healthcheck 200 "$healthy_sha"
  stub_response hub.trade-tariff.service.gov.uk/healthcheck 200 "$healthy_sha"
  stub_response id.trade-tariff.service.gov.uk/healthcheck 200 "$healthy_sha"
}

@test "healthcheck prints help" {
  run "$repo_root/bin/healthcheck" --help

  [ "$status" -eq 0 ]
  assert_contains "$output" "Usage: bin/healthcheck"
  assert_contains "$output" "FPO_API_KEY_PRODUCTION"
}

@test "healthcheck rejects an unknown environment with a usage error" {
  run "$repo_root/bin/healthcheck" qa

  [ "$status" -eq 2 ]
  assert_contains "$output" "Unknown argument: qa"
}

@test "healthcheck rejects a timeout that is not a positive number" {
  run "$repo_root/bin/healthcheck" --timeout 0

  [ "$status" -eq 2 ]
  assert_contains "$output" "--timeout needs a positive whole number"
}

@test "healthcheck checks production by default and passes when all services are healthy" {
  stub_healthy_production

  run "$repo_root/bin/healthcheck"

  [ "$status" -eq 0 ]
  assert_contains "$output" "All checks passed."
  assert_contains "$output" "postgres=ok redis=ok opensearch=ok sidekiq=ok sha=abc1234"
  assert_contains "$output" "sha=def5678"
  assert_not_contains "$output" "FAIL"
  assert_not_contains "$output" "staging"

  calls="$(cat "$STUB_RESPONSES/calls.txt")"
  assert_contains "$calls" "https://www.trade-tariff.service.gov.uk/uk/api/healthcheck"
  assert_contains "$calls" "https://www.trade-tariff.service.gov.uk/xi/api/healthcheck"
  assert_contains "$calls" "https://flags-edge.trade-tariff.service.gov.uk/proxy/health"
  assert_contains "$calls" "https://mcp.trade-tariff.service.gov.uk/healthcheckz"
}

@test "healthcheck reports the failed backend dependency from the 503 JSON" {
  stub_healthy_production
  stub_response www.trade-tariff.service.gov.uk/xi/api/healthcheck 503 \
    '{"git_sha1":"abc1234","sidekiq":true,"postgres":false,"redis":true,"opensearch":true,"healthy":false}'

  run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 1 ]
  assert_contains "$output" "backend-xi      FAIL   503"
  assert_contains "$output" "postgres=FAIL redis=ok"
  assert_contains "$output" "1 check(s) failed."
}

@test "healthcheck shows the CloudFront x-cache header for an error response" {
  stub_healthy_production
  stub_response admin.trade-tariff.service.gov.uk/healthcheck 503 '<html>503</html>'
  printf 'HTTP/2 503\r\nx-cache: Hit from cloudfront\r\n' > "$STUB_RESPONSES/admin.trade-tariff.service.gov.uk/healthcheck/headers"

  run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 1 ]
  assert_contains "$output" "HTTP 503 (x-cache: Hit from cloudfront)"
}

@test "healthcheck shows the x-cache header for a failed backend healthcheck" {
  stub_healthy_production
  stub_response www.trade-tariff.service.gov.uk/uk/api/healthcheck 503 \
    '{"git_sha1":"abc1234","sidekiq":true,"postgres":false,"redis":true,"opensearch":true,"healthy":false}'
  printf 'HTTP/2 503\r\nx-cache: Hit from cloudfront\r\n' > "$STUB_RESPONSES/www.trade-tariff.service.gov.uk/uk/api/healthcheck/headers"

  run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 1 ]
  assert_contains "$output" "postgres=FAIL redis=ok opensearch=ok sidekiq=ok sha=abc1234 (x-cache: Hit from cloudfront)"
}

@test "healthcheck shows the x-cache header for a 200 response that fails" {
  stub_healthy_production
  stub_response admin.trade-tariff.service.gov.uk/healthcheck 200 '<html>maintenance</html>'
  printf 'HTTP/2 200\r\nx-cache: Hit from cloudfront\r\n' > "$STUB_RESPONSES/admin.trade-tariff.service.gov.uk/healthcheck/headers"

  run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 1 ]
  assert_contains "$output" "response has no git_sha1 (x-cache: Hit from cloudfront)"
}

@test "healthcheck reports an unreachable service" {
  stub_healthy_production
  mkdir -p "$STUB_RESPONSES/hub.trade-tariff.service.gov.uk/healthcheck"
  echo 28 > "$STUB_RESPONSES/hub.trade-tariff.service.gov.uk/healthcheck/exit"

  run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 1 ]
  assert_contains "$output" "unreachable (curl exit 28: Operation timed out)"
}

@test "healthcheck does not report dependency failures for a backend JSON error" {
  stub_healthy_production
  stub_response www.trade-tariff.service.gov.uk/uk/api/healthcheck 404 '{"errors":[{"detail":"404 - Not Found"}]}'
  stub_response www.trade-tariff.service.gov.uk/xi/api/healthcheck 500 '{"error":"Internal Server Error"}'

  run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 1 ]
  assert_contains "$output" "backend-uk      FAIL   404"
  assert_contains "$output" "HTTP 404: 404 - Not Found"
  assert_contains "$output" "HTTP 500: Internal Server Error"
  assert_not_contains "$output" "postgres=FAIL"
}

@test "healthcheck fails a backend 200 JSON response without a healthy field" {
  stub_healthy_production
  stub_response www.trade-tariff.service.gov.uk/uk/api/healthcheck 200 '{"git_sha1":"abc1234"}'

  run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 1 ]
  assert_contains "$output" "response is not backend healthcheck JSON"
  assert_not_contains "$output" "postgres=FAIL"
}

@test "healthcheck fails a backend 200 response that is not healthcheck JSON" {
  stub_healthy_production
  stub_response www.trade-tariff.service.gov.uk/uk/api/healthcheck 200 '<html>Service maintenance</html>'

  run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 1 ]
  assert_contains "$output" "backend-uk      FAIL   200"
  assert_contains "$output" "response is not backend healthcheck JSON"
}

@test "healthcheck fails a 200 response without a git sha" {
  stub_healthy_production
  stub_response www.trade-tariff.service.gov.uk/healthcheck 200 '<html>maintenance</html>'

  run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 1 ]
  assert_contains "$output" "response has no git_sha1"
}

@test "healthcheck skips fpo search without an API key and calls it with one" {
  stub_healthy_production

  run "$repo_root/bin/healthcheck" production
  [ "$status" -eq 0 ]
  assert_contains "$output" "fpo-search      SKIP"
  assert_not_contains "$(cat "$STUB_RESPONSES/calls.txt")" "search.trade-tariff.service.gov.uk"

  stub_response search.trade-tariff.service.gov.uk/fpo-code-search 403 '{"message":"Forbidden"}'

  FPO_API_KEY_PRODUCTION=bad-key run "$repo_root/bin/healthcheck" production
  [ "$status" -eq 1 ]
  assert_contains "$output" "fpo-search      FAIL   403"
  assert_contains "$output" "HTTP 403: Forbidden"
}

@test "healthcheck uses the environment subdomains for all environments" {
  run "$repo_root/bin/healthcheck" all

  calls="$(cat "$STUB_RESPONSES/calls.txt")"
  assert_contains "$calls" "https://dev.trade-tariff.service.gov.uk/uk/api/healthcheck"
  assert_contains "$calls" "https://admin.dev.trade-tariff.service.gov.uk/healthcheck"
  assert_contains "$calls" "https://staging.trade-tariff.service.gov.uk/xi/api/healthcheck"
  assert_contains "$calls" "https://id.staging.trade-tariff.service.gov.uk/healthcheck"
  assert_contains "$calls" "https://www.trade-tariff.service.gov.uk/healthcheck"
  assert_contains "$calls" "https://hub.trade-tariff.service.gov.uk/healthcheck"
}

@test "healthcheck sends the FPO API key from a file and does not trace it" {
  stub_healthy_production
  stub_response search.trade-tariff.service.gov.uk/fpo-code-search 200 '{"results":[{"code":"960321","score":1.0}]}'

  FPO_API_KEY_PRODUCTION=secret-key-123 TRACE=1 run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 0 ]
  assert_contains "$output" "fpo-search      OK     200"
  assert_not_contains "$output" "secret-key-123"
  assert_not_contains "$(cat "$STUB_RESPONSES/header-args.txt")" "secret-key-123"
  assert_contains "$(cat "$STUB_RESPONSES/headers-sent.txt")" "X-Api-Key: secret-key-123"
}

@test "healthcheck skips fpo search when the environment key is empty" {
  stub_healthy_production

  FPO_API_KEY_PRODUCTION= run "$repo_root/bin/healthcheck" production

  [ "$status" -eq 0 ]
  assert_contains "$output" "fpo-search      SKIP"
}

@test "healthcheck sends each FPO API key only to its own environment" {
  stub_response search.staging.trade-tariff.service.gov.uk/fpo-code-search 200 '{"results":[{"code":"960321","score":1.0}]}'

  FPO_API_KEY_STAGING=staging-key run "$repo_root/bin/healthcheck" all

  assert_contains "$output" "staging      fpo-search      OK     200"
  assert_contains "$output" "development  fpo-search      SKIP   -     -       set FPO_API_KEY_DEVELOPMENT to check"
  assert_contains "$output" "production   fpo-search      SKIP   -     -       set FPO_API_KEY_PRODUCTION to check"

  calls="$(cat "$STUB_RESPONSES/calls.txt")"
  assert_contains "$calls" "https://search.staging.trade-tariff.service.gov.uk/fpo-code-search"
  assert_not_contains "$calls" "https://search.dev.trade-tariff.service.gov.uk"
  assert_not_contains "$calls" "https://search.trade-tariff.service.gov.uk"
  [ "$(cat "$STUB_RESPONSES/headers-sent.txt")" = "X-Api-Key: staging-key" ]
}

@test "healthcheck does not send a production FPO API key to staging" {
  FPO_API_KEY_PRODUCTION=production-key run "$repo_root/bin/healthcheck" staging

  assert_contains "$output" "staging      fpo-search      SKIP"
  assert_not_contains "$(cat "$STUB_RESPONSES/calls.txt")" "search."
  [ ! -f "$STUB_RESPONSES/headers-sent.txt" ]
}

@test "healthcheck ignores the old FPO_API_KEY variable" {
  FPO_API_KEY=unbound-key run "$repo_root/bin/healthcheck" production

  assert_contains "$output" "production   fpo-search      SKIP   -     -       set FPO_API_KEY_PRODUCTION to check"
  [ ! -f "$STUB_RESPONSES/headers-sent.txt" ]
}

@test "healthcheck accepts an environment twice when its FPO API key is set" {
  stub_response search.staging.trade-tariff.service.gov.uk/fpo-code-search 200 '{"results":[{"code":"960321","score":1.0}]}'

  FPO_API_KEY_STAGING=staging-key run "$repo_root/bin/healthcheck" all staging

  assert_contains "$output" "staging      fpo-search      OK     200"
  assert_not_contains "$output" "cannot overwrite"
}
