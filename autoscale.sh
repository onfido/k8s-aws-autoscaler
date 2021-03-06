#!/bin/bash

function notifySlack() {
  if [ -z "$SLACK_HOOK" ]; then
    return 0
  fi

  curl -s --retry 3 --retry-delay 3 -X POST --data-urlencode 'payload={"text": "'"$1"'"}' $SLACK_HOOK > /dev/null
}

multiAzNoWS=$(echo "$MULTI_AZ" | tr -d "[:space:]")
IFS=',' read -ra multiAZ <<< $multiAzNoWS

function asgMultiAzCheck() {
  local labels=$1
  local asgName=$2

  local selector="aws.autoscaling.groupName=$asgName,$labels"

  if [ -z "$MULTI_AZ" ]; then
    return 1
  fi

  local currentAZs=$(kubectl describe nodes -l $selector | \
    grep zone | awk -F "=" '{print $2}')

  local missingAZsArray=$(echo ${multiAZ[@]} ${currentAZs[@]} | tr ' ' '\n' | sort | uniq -u)

  if [[ $missingAZsArray == "" ]]; then
    return 1
  fi

  local missingAZs=""

  for zone in $missingAZsArray; do
    missingAZs+="$zone "
  done

  notifySlack "<!channel> ASG $asgName has no nodes in: $missingAZs."
  return 0
}

function getPods() {
  local labels=$1
  local jqSelectors=""

  IFS=',' read -ra labelsArr <<< "$labels"
  for label in "${labelsArr[@]}"; do
    IFS='=' read key value <<< "$label"
    jqSelectors+="| select(.spec.nodeSelector.$key == \"$value\")"
  done

  kubectl get pods --all-namespaces -o json | jq ".items[] $jqSelectors"
}

function countPendingPods() {
  # If hostIP == null then pod is Pending and not scheduled to a node.
  # If hostIP == null && deletionTimestamp != null, then the pod has hung during deletion (usually because .status.reason == NodeLost)
  getPods $1 | jq 'select(.status.hostIP == null and .metadata.deletionTimestamp == null and .status.phase != "Failed") | .metadata.name' | wc -l
}

function countRunningPods() {
  getPods $1 | jq 'select(.status.phase == "Running") | .metadata.name' | wc -l
}

function getNodesRRA() {
  local labels=$1

  for i in $(seq 5); do
    nodesDescription=$(kubectl describe nodes -l $labels)
    descriptionStatus=$?

    [ $descriptionStatus -eq 0 ] && break
    sleep 3
  done

  # If nodes description fail
  if [[ $descriptionStatus -ne 0 ]]; then
    echo "Master unreachable"
    return 0
  elif [[ $nodesDescription == "" ]]; then
    # If nodes description was successful but no nodes were found, echo -1
    echo -1
    return 0
  fi

  # Gets requested CPU and RAM resources for nodes with current labels
  local results=$(echo "$nodesDescription" | grep -A3 "Total limits may be over 100 percent" | \
    grep -E '^\s+[0-9]+' | awk '{ print $2, " ", $6 }' | grep -oE '[0-9]{1,3}')

  local counter=0
  local sum=0
  for i in $results; do
    counter=$(expr $counter + 1)
    sum=$(expr $sum + $i)
  done

  # Returns average of requested CPU/RAM for nodes with current labels
  echo "$sum / $counter" | bc
}

function describeAutoscaling() {
  local asgName=$1
  local asgRegion=$2

  for i in $(seq 5); do
    local description=$(aws autoscaling describe-auto-scaling-groups \
          --auto-scaling-group-name $asgName --region $asgRegion)

    [ $? -eq 0 ] && echo "$description" && return 0
    sleep 3
  done

  return 1
}

function getASGDesiredCapacity() {
  describeAutoscaling $1 $2 | jq '.AutoScalingGroups[].DesiredCapacity'
}

function getASGMinSize() {
  describeAutoscaling $1 $2 | jq '.AutoScalingGroups[].MinSize'
}

function getASGMaxSize() {
  describeAutoscaling $1 $2 | jq '.AutoScalingGroups[].MaxSize'
}

function scaleUp() {
  local asgName=$1
  local asgRegion=$2
  local nodeToAddCount=$3

  local currentNodeCount=$(getASGDesiredCapacity $asgName $asgRegion)
  local maxNodeCount=$(getASGMaxSize $asgName $asgRegion)

  if [ $(expr $currentNodeCount + $nodeToAddCount) -gt $maxNodeCount ]; then
    nodeToAddCount=$(expr $maxNodeCount - $currentNodeCount)
  fi

  for i in $(seq 5); do
    aws autoscaling set-desired-capacity --auto-scaling-group-name $asgName \
          --desired-capacity $(expr $currentNodeCount + $nodeToAddCount) --region $asgRegion

    [ $? -eq 0 ] && return 0
    sleep 3
  done

  return 1
}

function scaleDown() {
  local asgName=$1
  local asgRegion=$2

  local currentNodeCount=$(getASGDesiredCapacity $asgName $asgRegion)
  local minNodeCount=$(getASGMinSize $asgName $asgRegion)

  if [[ $currentNodeCount -eq $minNodeCount ]]; then
    echo "$(date) -- Hit minimum nodes on $asgName ASG."
    return 1
  fi

  for i in $(seq 5); do
    # Get the oldest node in the ASG
    nodeName=$(kubectl get nodes -l aws.autoscaling.groupName=$asgName \
      --sort-by='{.metadata.creationTimestamp}' | awk '{ if(NR==2) print $1 }')

    nodeId=$(kubectl describe node $nodeName | grep "ExternalID:" | awk '{ print $2 }')

    if [[ $nodeName != "" && $nodeId != "" ]]; then
      aws autoscaling detach-instances --instance-ids $nodeId --auto-scaling-group-name $asgName \
        --should-decrement-desired-capacity --region $asgRegion

      if [[ $? -ne 0 ]]; then
        echo "$(date) -- $nodeId already detached from $asgName."
      fi

      kubectl drain $nodeName --ignore-daemonsets --grace-period=90 --delete-local-data --force --timeout=480s

      sleep 30

      aws ec2 terminate-instances --instance-ids $nodeId --region $asgRegion

      return 0
    fi

    sleep 3
  done

  notifySlack "<!channel> Failed to scale down $asgName, no nodes found or master unreachable."
  return 1
}

autoscalingNoWS=$(echo "$AUTOSCALING" | tr -d "[:space:]")
IFS=';' read -ra autoscalingArr <<< "$autoscalingNoWS"

RRAs=()

function main() {
  local index=0

  for autoscaler in "${autoscalingArr[@]}"; do
    IFS='|' read minRRA maxRRA asgName labels asgRegion <<< "$autoscaler"

    pendingPods=$(countPendingPods $labels)
    # +1 as it's an integer division and we want ceil of it.

    if [[ $pendingPods -gt 0 ]]; then
      local runningPods=$(countRunningPods $labels)
      local newNodesRequiredCount=$(expr $pendingPods \* $(getASGDesiredCapacity $asgName $asgRegion) / $runningPods + 1)

      echo "$(date) -- Pending pods ($pendingPods). Scaling up $asgName ASG by $newNodesRequiredCount."
      scaleUp $asgName $asgRegion $newNodesRequiredCount

      if [[ $? -eq 0 ]]; then
        notifySlack "Pending pods ($pendingPods). Scaling up $asgName ASG by $newNodesRequiredCount."
      fi

      asgMultiAzCheck $labels $asgName
    else
      local currentRRA=$(getNodesRRA $labels)

      # Check that getNodesRRA returned a 1-3 digit number
      if [[ ${#currentRRA} -gt 0 && ${#currentRRA} -lt 4 ]]; then
        # Check that getNodesRRA didn't return -1 (no nodes found)
        if [[ $currentRRA -ne -1 ]]; then

          # Only print currentRRA when previous reading doesn't exist or is different
          if [[ -z ${RRAs[$index]} || (! -z ${RRAs[$index]} && ${RRAs[$index]} -ne $currentRRA) ]]; then
            echo "$(date) -- $currentRRA% RRA for $asgName."
            RRAs[$index]=$currentRRA
          fi

          if [[ $currentRRA -gt $maxRRA ]]; then
            local newNodesRequiredCount=$(expr $(expr $currentRRA - $maxRRA) \* $(getASGDesiredCapacity $asgName $asgRegion) / $maxRRA + 1)
            echo "$(date) -- $currentRRA% > $maxRRA%. Scaling up $asgName ASG by $newNodesRequiredCount."
            scaleUp $asgName $asgRegion $newNodesRequiredCount

            if [[ $? -eq 0 ]]; then
              notifySlack "$currentRRA% > $maxRRA%. Scaling up $asgName ASG by $newNodesRequiredCount."
            fi

          elif [[ $currentRRA -lt $minRRA ]]; then
            echo "$(date) -- $currentRRA% < $minRRA%. Scaling down $asgName."
            scaleDown $asgName $asgRegion

            if [[ $? -eq 0 ]]; then
              notifySlack "$currentRRA% < $minRRA%. Scaling down $asgName."
            fi
          fi

        else
          notifySlack "<!channel> ASG $asgName has no nodes."
          scaleUp $asgName $asgRegion 1

          if [[ $? -eq 0 ]]; then
            notifySlack "Pending pods. Scaling up $asgName ASG by 1."
          fi
        fi

      else
        notifySlack "Failed to calculate nodes RRA for $asgName."
      fi
    fi

    (( index++ ))
    sleep 3
  done
}


while true; do
  main
  sleep $INTERVAL
done
