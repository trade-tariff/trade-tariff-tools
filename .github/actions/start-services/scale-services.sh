#!/usr/bin/env bash

[[ "$TRACE" ]] && set -o xtrace
set -o errexit
set -o nounset
set -o pipefail
set -o noclobber

usage() {
  cat <<'EOF'
Usage: scale-services.sh --cluster <name> --region <region> --desired-count <n> --verb <start|stop> <service-name>...

Set the desired task count of each ECS service. Each service must be ACTIVE.

Arguments:
  --cluster <name>      ECS cluster name.
  --region <region>     AWS region, for example eu-west-2.
  --desired-count <n>   Desired task count for each service.
  --verb <start|stop>   Selects the words in log messages.
  <service-name>...     One or more ECS service names.

Environment:
  AWS credentials for the aws CLI (required).

Exit codes:
  0  All services were updated.
  1  One or more services were not found or did not update.
  2  Usage error.
EOF
}

cluster=""
region=""
desired_count=""
verb=""
service_names=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)
      cluster="${2:-}"
      shift 2 || shift
      ;;
    --region)
      region="${2:-}"
      shift 2 || shift
      ;;
    --desired-count)
      desired_count="${2:-}"
      shift 2 || shift
      ;;
    --verb)
      verb="${2:-}"
      shift 2 || shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      service_names+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$cluster" ]]; then
  echo "Missing required argument: --cluster" >&2
  exit 2
fi

if [[ -z "$region" ]]; then
  echo "Missing required argument: --region" >&2
  exit 2
fi

if [[ -z "$desired_count" ]]; then
  echo "Missing required argument: --desired-count" >&2
  exit 2
fi

case "$verb" in
  start)
    verb_ing="Starting"
    verb_past="Started"
    verb_past_lower="started"
    ;;
  stop)
    verb_ing="Stopping"
    verb_past="Stopped"
    verb_past_lower="stopped"
    ;;
  *)
    echo "Invalid --verb: $verb (expected start or stop)" >&2
    exit 2
    ;;
esac

if [[ ${#service_names[@]} -eq 0 ]]; then
  echo "At least one service name is required." >&2
  usage >&2
  exit 2
fi

succeeded=()
failed=()

for service_name in "${service_names[@]}"; do
  echo "::group::${verb_ing} service: $service_name"

  if ! aws ecs describe-services \
    --cluster "$cluster" \
    --services "$service_name" \
    --region "$region" \
    --query "services[?status=='ACTIVE'].serviceName" \
    --output text | grep -q "$service_name"; then
    echo "::error::Service '$service_name' does not exist or is not active in cluster '$cluster'"
    failed+=("$service_name (not found)")
    echo "::endgroup::"
    continue
  fi

  if aws ecs update-service \
    --cluster "$cluster" \
    --service "$service_name" \
    --desired-count "$desired_count" \
    --region "$region" \
    --output text \
    --query "service.{name:serviceName,desired:desiredCount,running:runningCount}" > /dev/null; then
    echo "::notice::✓ ${verb_past} $service_name (desired count: $desired_count)"
    succeeded+=("$service_name")
  else
    echo "::error::✗ Failed to $verb $service_name"
    failed+=("$service_name")
  fi

  echo "::endgroup::"
done

echo ""
echo "=========================================="
echo "Summary:"
echo "=========================================="

if [[ ${#succeeded[@]} -gt 0 ]]; then
  echo "::notice::✓ Successfully ${verb_past_lower} ${#succeeded[@]} service(s):"
  for service_name in "${succeeded[@]}"; do
    echo "::notice::  - $service_name"
  done
fi

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "::error::✗ Failed to $verb ${#failed[@]} service(s):"
  for service_name in "${failed[@]}"; do
    echo "::error::  - $service_name"
  done
  exit 1
fi

echo "::notice::All services ${verb_past_lower} successfully!"
