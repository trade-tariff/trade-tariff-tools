#!/usr/bin/env bash

declare -ga PRESERVE_FAMILY_SUFFIXES=(
  "-job"
)

family_is_preserved() {
  local family="$1"

  for suffix in "${PRESERVE_FAMILY_SUFFIXES[@]}"; do
    if [[ "$family" == *"$suffix" || "$family" == *"$suffix"-* ]]; then
      return 0
    fi
  done

  return 1
}

task_definition_family() {
  local task_definition_arn="$1"
  local family_revision="${task_definition_arn##*/}"
  echo "${family_revision%:*}"
}

list_active_task_definition_families() {
  aws ecs list-task-definition-families \
    --status ACTIVE \
    --query 'families[]' \
    --output text
}

list_exact_active_task_definition_revisions() {
  local family="$1"
  local revisions

  revisions=$(aws ecs list-task-definitions \
    --family-prefix "$family" \
    --status ACTIVE \
    --query 'taskDefinitionArns[]' \
    --output text)

  for revision_arn in $revisions; do
    if [[ "$(task_definition_family "$revision_arn")" == "$family" ]]; then
      echo "$revision_arn"
    fi
  done
}
