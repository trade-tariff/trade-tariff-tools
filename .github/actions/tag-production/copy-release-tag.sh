#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF_USAGE'
Usage: copy-release-tag.sh

Add a release-<date> tag to an image in ECR without a pull. A docker pull and
push copies only the platform of the runner, so a multi-arch image needs a
registry-side copy of the whole manifest.

Environment:
  ECR_URL  (required) ECR repository URL: <registry>/<repository>.
  REF      (required) Tag of the image to copy.
  REGION   (optional, default: eu-west-2) AWS region of the ECR repository.

Exit codes:
  0  The release tag is pushed.
  1  The image is not in ECR, or the copy failed.
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

for name in ECR_URL REF; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 2
  fi
done

region="${REGION:-eu-west-2}"
registry_host="${ECR_URL%%/*}"
registry_id="${registry_host%%.*}"
repository="${ECR_URL#*/}"
existing_image="$ECR_URL:$REF"
release_image="$ECR_URL:release-$(date +"%Y%m%d-%H%M")"

aws ecr get-login-password --region "$region" \
  | docker login --username AWS --password-stdin "$ECR_URL"

if ! aws ecr describe-images \
  --repository-name "$repository" \
  --image-ids imageTag="$REF" \
  --region "$region" \
  --registry-id "$registry_id" > /dev/null 2>&1; then
  echo "::error::Image $existing_image not found in ECR. Fatal skipping tagging"
  exit 1
fi

# --prefer-index=false copies a single image manifest as it is, instead of wrapping it in an index.
docker buildx imagetools create --prefer-index=false -t "$release_image" "$existing_image"

echo "::notice::Successfully pushed $release_image"
