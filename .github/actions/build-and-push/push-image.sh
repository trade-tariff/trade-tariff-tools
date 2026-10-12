#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: push-image.sh

Push a Docker image to ECR. If the push fails because another run pushed the
same immutable tag first, treat the push as successful.

Environment:
  IMAGE_NAME  (required) Full image name: <registry>/<repository>:<tag>.
  REGION      (optional, default: eu-west-2) AWS region of the ECR repository.

Exit codes:
  0  Image pushed, or the tag already exists in ECR.
  1  Push failed and the tag is not in ECR.
  2  Usage error.
EOF
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

if [[ -z "${IMAGE_NAME:-}" ]]; then
  echo "Missing required environment variable: IMAGE_NAME" >&2
  exit 2
fi

region="${REGION:-eu-west-2}"
registry_host="${IMAGE_NAME%%/*}"
registry_id="${registry_host%%.*}"
repository_and_tag="${IMAGE_NAME#*/}"
repository="${repository_and_tag%:*}"
tag="${repository_and_tag##*:}"

if docker push "$IMAGE_NAME"; then
  exit 0
fi

# Two runs for the same commit can both pass the existence check and build.
# The tag is the commit SHA, so the image that the other run pushed is the same.
if aws ecr describe-images \
  --repository-name "$repository" \
  --image-ids imageTag="$tag" \
  --region "$region" \
  --registry-id "$registry_id" > /dev/null 2>&1; then
  echo "::notice::Image $IMAGE_NAME already exists in ECR. Another run pushed it first."
  exit 0
fi

echo "::error::Failed to push $IMAGE_NAME"
exit 1
