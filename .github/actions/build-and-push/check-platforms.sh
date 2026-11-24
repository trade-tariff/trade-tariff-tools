#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: check-platforms.sh

Check that an image tag in ECR has a build for every requested platform. ECR
tags are immutable, so a tag without a platform cannot get it later.

Environment:
  IMAGE_NAME  (required) Full image name: <registry>/<repository>:<tag>.
  PLATFORMS   (required) Comma-separated platforms, for example
              linux/amd64,linux/arm64.
  REGION      (optional, default: eu-west-2) AWS region of the ECR repository.

A tag with a single image manifest (not an index) counts as linux/amd64,
because all single-platform images before multi-arch builds were amd64.

Exit codes:
  0  The tag has a build for every requested platform.
  1  The tag has no build for one or more platforms, or ECR did not return it.
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

for name in IMAGE_NAME PLATFORMS; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: $name" >&2
    exit 2
  fi
done

region="${REGION:-eu-west-2}"
registry_host="${IMAGE_NAME%%/*}"
registry_id="${registry_host%%.*}"
repository_and_tag="${IMAGE_NAME#*/}"
repository="${repository_and_tag%:*}"
tag="${repository_and_tag##*:}"

if ! manifest="$(aws ecr batch-get-image \
  --repository-name "$repository" \
  --image-ids imageTag="$tag" \
  --region "$region" \
  --registry-id "$registry_id" \
  --accepted-media-types \
    application/vnd.docker.distribution.manifest.list.v2+json \
    application/vnd.oci.image.index.v1+json \
    application/vnd.docker.distribution.manifest.v2+json \
    application/vnd.oci.image.manifest.v1+json \
  --query 'images[0].imageManifest' \
  --output text)"; then
  echo "::error::Could not read the manifest of $IMAGE_NAME"
  exit 1
fi

available="$(jq -r '
  if .manifests
  then [.manifests[].platform | "\(.os)/\(.architecture)" + (if .variant then "/\(.variant)" else "" end)]
  else ["linux/amd64"]
  end
  | join(",")
' <<< "$manifest")"

# An entry with a variant also matches a request without one: linux/arm64 matches linux/arm64/v8.
matchable=",$available,"
for entry in ${available//,/ }; do
  matchable+="$(cut -d/ -f1,2 <<< "$entry"),"
done

missing=()
for platform in ${PLATFORMS//,/ }; do
  if [[ "$matchable" != *",$platform,"* ]]; then
    missing+=("$platform")
  fi
done

if (( ${#missing[@]} > 0 )); then
  echo "::error::Image $IMAGE_NAME has no build for ${missing[*]}. It has $available. ECR tags are immutable: deploy a new commit to build a new tag."
  exit 1
fi

echo "::notice::Image $IMAGE_NAME has a build for every platform in $PLATFORMS."
