#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF_USAGE'
Usage: validate-platforms.sh

Check the platforms input of the build-and-push action. Every image must keep
a linux/amd64 build, so that a deploy with the default platform can always use
an existing tag.

Environment:
  PLATFORMS  (required) Comma-separated platforms. Allowed values are
             linux/amd64 and linux/arm64. linux/amd64 is required.

Exit codes:
  0  The platforms are valid.
  1  The platforms are not valid.
  2  Usage error.
EOF_USAGE
}

case "${1:-}" in
  "")
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ -z "${PLATFORMS:-}" ]]; then
  echo "Missing required environment variable: PLATFORMS" >&2
  exit 2
fi

has_amd64=false
for platform in ${PLATFORMS//,/ }; do
  case "$platform" in
    linux/amd64)
      has_amd64=true
      ;;
    linux/arm64)
      ;;
    *)
      echo "::error::Platform $platform is not supported. Use linux/amd64 or linux/arm64."
      exit 1
      ;;
  esac
done

if [[ "$has_amd64" != true ]]; then
  echo "::error::Platforms $PLATFORMS must include linux/amd64."
  exit 1
fi
