#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: run-e2e-tests.sh

Run selected Playwright projects from the E2E suite directory.

Arguments:
  -h, --help  Print this help.

Environment:
  PROJECTS                       (required) Comma-separated project names:
                                 api, admin, frontend, dev-hub, myott.
  TEST_ENVIRONMENT               (required) Environment to test.
  SKIP_PASSWORDLESS_VERIFICATION (optional, default: true) true or false.
                                 Set false when passwordless verification is needed.

Outputs:
  Test output on stdout and stderr. No GitHub outputs.

Exit codes:
  0  Tests passed.
  1  Tests failed.
  2  Usage error or Make failure.
EOF
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

for required_name in PROJECTS TEST_ENVIRONMENT; do
  if [[ -z "${!required_name:-}" ]]; then
    echo "Missing required environment variable: $required_name" >&2
    exit 2
  fi
done

skip_passwordless="${SKIP_PASSWORDLESS_VERIFICATION-true}"
case "$skip_passwordless" in
  true|false) ;;
  *) echo "SKIP_PASSWORDLESS_VERIFICATION must be true or false" >&2; exit 2 ;;
esac

selected_projects=()
remaining="${PROJECTS},"
while [[ -n "$remaining" ]]; do
  project="${remaining%%,*}"
  remaining="${remaining#*,}"
  project="${project#"${project%%[![:space:]]*}"}"
  project="${project%"${project##*[![:space:]]}"}"

  case "$project" in
    api|frontend|admin|dev-hub|myott) ;;
    "") echo "PROJECTS must contain nonempty project names" >&2; exit 2 ;;
    *) echo "Unsupported E2E project: $project" >&2; exit 2 ;;
  esac
  selected_projects+=("$project")
done

printf -v normalised_projects '%s,' "${selected_projects[@]}"
export SKIP_PASSWORDLESS_VERIFICATION="$skip_passwordless"
make test "environment=$TEST_ENVIRONMENT" "projects=${normalised_projects%,}"
