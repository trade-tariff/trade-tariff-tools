#!/usr/bin/env bash

[[ "${TRACE:-}" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail

usage() {
  cat <<'USAGE'
Usage: apply.sh

Apply the Terraform in terraform/ with the var file of the environment.

Run it from the application repository root, which has terraform/.

Environment:
  ENVIRONMENT  (required) The environment, for example uat.
  VARS         (optional) Terraform variables, one name=value on each line.
               They come after the var file, so they replace its values.
USAGE
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${ENVIRONMENT:-}" ]]; then
  echo "Missing required environment variable: ENVIRONMENT" >&2
  exit 2
fi

args=(apply "-var-file=config_${ENVIRONMENT}.tfvars")

while IFS= read -r var; do
  if [[ -n "$var" ]]; then
    args+=(-var "$var")
  fi
done <<<"${VARS:-}"

args+=(-auto-approve -lock-timeout=10m)

cd terraform && terraform "${args[@]}"
