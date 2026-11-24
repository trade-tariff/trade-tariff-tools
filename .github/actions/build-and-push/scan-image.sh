#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF_USAGE'
Usage: scan-image.sh

Scan an image in ECR with Trivy, one time for each platform. The scan reads
the image from the registry, so it checks the exact content that a later step
tags. Any CRITICAL or HIGH finding with a fix stops the scan.

Environment:
  SOURCE_IMAGE  (required) Image in ECR: <registry>/<repository>@<digest>.
  PLATFORMS     (required) Comma-separated platforms.

Exit codes:
  0  No platform has a CRITICAL or HIGH finding with a fix.
  1  Trivy found a vulnerability or failed.
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

for name in SOURCE_IMAGE PLATFORMS; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 2
  fi
done

for platform in ${PLATFORMS//,/ }; do
  echo "::notice::Scanning $SOURCE_IMAGE for $platform"
  trivy image --image-src remote --platform "$platform" \
    --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 "$SOURCE_IMAGE"
done
