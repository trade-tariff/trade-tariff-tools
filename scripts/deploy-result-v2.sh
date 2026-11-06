#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: deploy-result-v2.sh

Resolve the deployment result and notification summary.

Arguments:
  -h, --help  Print this help.

Environment:
  BUILD_RESULT     (required) Build job result.
  DEPLOY_RESULT    (required) Deployment job result.
  ENVIRONMENT      (required) Deployment environment.
  TEST_PROJECTS    (required, may be empty) Selected E2E projects.
  E2E_TEST_RESULT  (required when TEST_PROJECTS is nonempty) E2E job result.
  GITHUB_OUTPUT    (optional, default: /dev/stdout) Output destination.

Outputs:
  result and summary GitHub outputs.

Exit codes:
  0  Result resolved.
  1  Output write failed.
  2  Usage error.
EOF
}

case "${1:-}" in
  "") ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

for required_name in BUILD_RESULT DEPLOY_RESULT ENVIRONMENT; do
  if [[ -z "${!required_name:-}" ]]; then
    echo "Missing required environment variable: $required_name" >&2
    exit 2
  fi
done

if [[ "$ENVIRONMENT" == *[[:cntrl:]]* ]]; then
  echo "Environment contains control characters: ENVIRONMENT" >&2
  exit 2
fi

if [[ "${TEST_PROJECTS+x}" != x ]]; then
  echo "Missing required environment variable: TEST_PROJECTS" >&2
  exit 2
fi

if [[ "$BUILD_RESULT" == "failure" ]]; then
  result="failure"
  summary="Deploy to ${ENVIRONMENT} failed during build"
elif [[ "$DEPLOY_RESULT" == "failure" ]]; then
  result="failure"
  summary="Deploy to ${ENVIRONMENT} failed during deployment"
else
  if [[ "$BUILD_RESULT" != "success" ]]; then
    result="$BUILD_RESULT"
  elif [[ "$DEPLOY_RESULT" != "success" || -z "$TEST_PROJECTS" ]]; then
    result="$DEPLOY_RESULT"
  elif [[ -z "${E2E_TEST_RESULT:-}" ]]; then
    echo "Missing required environment variable: E2E_TEST_RESULT" >&2
    exit 2
  else
    result="$E2E_TEST_RESULT"
  fi

  summary="Deploy to ${ENVIRONMENT} ${result}"
fi

{
  printf 'result=%s\n' "$result"
  printf 'summary<<DEPLOY_SUMMARY_EOF\n%s\nDEPLOY_SUMMARY_EOF\n' "$summary"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
