#!/bin/sh

command=$2
if [ "${command}x" == "x" ]; then
  command="bin/rails c"
fi

cluster=$(aws ecs list-clusters | jq -r '.clusterArns[]')
service=$(aws ecs list-services --cluster "${cluster}" | jq -r '.serviceArns[]' | grep "worker-${1}")
task=$(aws ecs list-tasks --cluster "${cluster}" --service-name "${service}" | jq -r '.taskArns[]')


echo "using: $(echo $cluster | cut -d '/' -f 2 | cut -d '-' -f 4 | tr a-z A-Z)"
sleep 4
aws ecs execute-command --cluster $cluster --task $task --container "worker-${1}" --interactive --command "/bin/sh -c \"RAILS_LOG_LEVEL=debug ${command}\""
