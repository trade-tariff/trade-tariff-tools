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
  IMAGE_NAME    (required) Full image name: <registry>/<repository>:<tag>.
  REGION        (optional, default: eu-west-2) AWS region of the ECR repository.
  PLATFORMS     (optional) Comma-separated platforms. When set, tag
                SOURCE_IMAGE as IMAGE_NAME instead of a docker push. If another
                run pushed the tag first, check that it has every platform.
  SOURCE_IMAGE  (required with PLATFORMS) Space-separated images that are
                already in ECR, one for each platform:
                <registry>/<repository>@<digest>.

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

if [[ -n "${PLATFORMS:-}" && -z "${SOURCE_IMAGE:-}" ]]; then
  echo "Missing required environment variable: SOURCE_IMAGE" >&2
  exit 2
fi

if [[ -n "${PLATFORMS:-}" ]]; then
  read -ra source_images <<< "$SOURCE_IMAGE"
  IFS=, read -ra platforms <<< "$PLATFORMS"
  if (( ${#source_images[@]} != ${#platforms[@]} )); then
    echo "::error::Got ${#source_images[@]} source images for ${#platforms[@]} platforms ($PLATFORMS). Each platform needs its own scanned image."
    exit 1
  fi
fi

region="${REGION:-eu-west-2}"
registry_host="${IMAGE_NAME%%/*}"
registry_id="${registry_host%%.*}"
repository_and_tag="${IMAGE_NAME#*/}"
repository="${repository_and_tag%:*}"
tag="${repository_and_tag##*:}"

push() {
  if [[ -z "${PLATFORMS:-}" ]]; then
    docker push "$IMAGE_NAME"
    return
  fi

  docker buildx imagetools create -t "$IMAGE_NAME" "${source_images[@]}"
}

if push; then
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
  if [[ -n "${PLATFORMS:-}" ]]; then
    exec "$(dirname "${BASH_SOURCE[0]}")/check-platforms.sh"
  fi
  exit 0
fi

echo "::error::Failed to push $IMAGE_NAME"
exit 1
