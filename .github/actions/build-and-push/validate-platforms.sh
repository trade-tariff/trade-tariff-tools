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

A digest-only run builds the arm64 half of a multi-arch image natively, so the
platforms must include linux/arm64 and the runner must be arm64.

Environment:
  PLATFORMS    (required) Comma-separated platforms. Allowed values are
               linux/amd64 and linux/arm64. linux/amd64 is required.
  DIGEST_ONLY  (optional, default: false) true or false. When true, PLATFORMS
               must include linux/arm64 and RUNNER_ARCH must be ARM64.
  RUNNER_ARCH  (optional) Runner architecture, set by GitHub Actions.

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

# docker buildx receives PLATFORMS unchanged, so reject any spelling that it would not accept.
if [[ ! "$PLATFORMS" =~ ^[^,[:space:]]+(,[^,[:space:]]+)*$ ]]; then
  echo "::error::Platforms '$PLATFORMS' must be a comma-separated list without spaces, for example linux/amd64,linux/arm64."
  exit 1
fi

digest_only="${DIGEST_ONLY:-false}"
# GitHub Actions compares strings without case, so accept only the exact values.
if [[ "$digest_only" != true && "$digest_only" != false ]]; then
  echo "::error::digest-only must be true or false, not $digest_only."
  exit 1
fi

has_amd64=false
IFS=, read -ra platforms <<< "$PLATFORMS"
for platform in "${platforms[@]}"; do
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

if [[ "$digest_only" == true ]]; then
  if [[ ",$PLATFORMS," != *,linux/arm64,* ]]; then
    echo "::error::A digest-only build needs linux/arm64 in platforms $PLATFORMS."
    exit 1
  fi
  if [[ "${RUNNER_ARCH:-}" != ARM64 ]]; then
    echo "::error::A digest-only build needs an arm64 runner. This runner is ${RUNNER_ARCH:-unknown}."
    exit 1
  fi
fi
