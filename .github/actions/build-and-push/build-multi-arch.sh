#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF_USAGE'
Usage: build-multi-arch.sh

Build a multi-arch image from the Dockerfile in the current directory and push
it to ECR by digest, without a tag. A later step scans the digest and then
tags it, so a tag never points at unscanned content.

The build uses --provenance=false, the same as the single-platform build.
Provenance attestations add an unknown/unknown entry to the index, and nothing
reads them today. Remove the flag to turn them back on.

Environment:
  ECR_URL     (required) ECR repository URL: <registry>/<repository>.
  REF         (required) Image tag. The script writes it to REVISION.
  PLATFORMS   (required) Comma-separated platforms.
  BUILD_ARGS  (optional) Extra docker buildx arguments.
  RUNNER_TEMP (optional) Directory for the build metadata file.

Outputs (to GITHUB_OUTPUT, default stdout):
  image_name    <registry>/<repository>:<REF>
  source_image  <registry>/<repository>@<digest>

Exit codes:
  0  The image is pushed by digest.
  1  The build or push failed.
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

for name in ECR_URL REF PLATFORMS; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 2
  fi
done

metadata="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/build-metadata.XXXXXX")"
read -ra build_args <<< "${BUILD_ARGS:-}"

echo "$REF" >| REVISION
docker buildx build --provenance=false --platform "$PLATFORMS" \
  --output "type=image,name=$ECR_URL,push-by-digest=true,name-canonical=true,push=true" \
  --metadata-file "$metadata" \
  ${build_args[@]+"${build_args[@]}"} .

digest="$(jq -r '."containerimage.digest" // empty' "$metadata")"
if [[ -z "$digest" ]]; then
  echo "::error::The build did not report an image digest."
  exit 1
fi

{
  echo "image_name=$ECR_URL:$REF"
  echo "source_image=$ECR_URL@$digest"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
