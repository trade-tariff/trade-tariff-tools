#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

if [[ "$BUILD_RESULT" == "failure" ]]; then
  result="failure"
  summary="Deploy to ${ENVIRONMENT} failed during build"
elif [[ "$DEPLOY_RESULT" == "failure" ]]; then
  result="failure"
  summary="Deploy to ${ENVIRONMENT} failed during deployment"
else
  case "$TEST_FLAVOUR" in
    tariff)
      result="$TARIFF_TEST_RESULT"
      ;;
    fpo)
      result="$FPO_TEST_RESULT"
      ;;
    *)
      result="$DEPLOY_RESULT"
      ;;
  esac

  summary="Deploy to ${ENVIRONMENT} ${result}"
fi

{
  echo "result=${result}"
  echo "summary=${summary}"
} >> "$GITHUB_OUTPUT"
