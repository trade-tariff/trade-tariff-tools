#!/usr/bin/env bash

[[ "${TRACE:-}" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail

usage() {
  cat <<'EOF'
Usage: force-unlock-own-lock.sh

Remove the Terraform state lock after a cancelled destroy, but only when this
runner holds it. A lock that another run holds stays.

Run it from the application repository root, which has terraform/backends.

Environment:
  ENVIRONMENT  (required) The environment, for example uat.
EOF
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${ENVIRONMENT:-}" ]]; then
  echo "Missing required environment variable: ENVIRONMENT" >&2
  exit 2
fi

backend="terraform/backends/${ENVIRONMENT}.tfbackend"
bucket=$(grep '^bucket' "$backend" | awk -F'"' '{print $2}')
key=$(grep '^key' "$backend" | awk -F'"' '{print $2}')

lock_file=$(mktemp)
trap 'rm -f "$lock_file"' EXIT

if ! aws s3 cp "s3://${bucket}/${key}.tflock" "$lock_file" > /dev/null; then
  echo "::notice::No state lock to remove."
  exit 0
fi

# Terraform writes the lock holder as <user>@<host>.
if [[ "$(jq -r '.Who' "$lock_file")" != "$(whoami)@$(hostname)" ]]; then
  echo "::notice::The state lock belongs to another run. It stays."
  exit 0
fi

lock_id=$(jq -r '.ID' "$lock_file")
cd terraform && terraform force-unlock -force "$lock_id"
