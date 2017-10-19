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
  local selector=$1
  local asgName=$2

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

function countPendingPods() {
  local asgName=$1

  # Gets pending pods older than 1min
  local pendingPods=$(kubectl get pods --all-namespaces | \
    grep -E '([a-zA-Z0-9-]+\s+){2}[0-9/]+\s+Pending+(\s+[0-9]+){2}[mh]' | \
    sed 's/(m|h)$//g' | awk '$6 >= 1 { print $1 "|" $2 }')

  countPodsInAsg $pendingPods $asgName
}

function getRunningPods() {
  local asgName=$1

  local runningPods=$(kubectl get pods --all-namespaces | grep Running | awk '{ print $1 "|" $2 }')

  countPodsInAsg $runningPods $asgName
}

function countPodsInAsg() {
  local pods=$1
  local asgName=$2

  local checkedSelectors=()
  local countPods=0

  for pod in $pods; do
    IFS='|' read namespace podName <<< "$pod"

    # Gets pending pod node selector
    local nodeSelector=$(kubectl describe pod -n $namespace $podName | \
      sed -n '/Node-Selectors:/{:a;p;n;/^Tolerations:/!ba}' | \
      sed 's/\t//g;s/Node-Selectors://' | tr '\n' ',' | sed 's/,$//g')

    # Checks if node selector not empty and if it hasn't already been checked against current ASG
    if [[ $nodeSelector != "" && ! "${checkedSelectors[@]}" =~ "${nodeSelector}" ]]; then
      checkedSelectors+=($nodeSelector)

      local selectorMatchesASG=""
      selectorMatchesASG=$(kubectl get nodes -l aws.autoscaling.groupName=$asgName,$nodeSelector 2> /dev/null)

      # If node selector exists as label on the same nodes as ASG, pod is pending on that ASG
      if [[ $selectorMatchesASG != "" ]]; then
        local selector="aws.autoscaling.groupName=$asgName,$nodeSelector"
        asgMultiAzCheck $selector $asgName

        countPods=$(expr $countPods + 1)
      fi
    fi
  done

  return $countPods
}

function getNodesRRA() {
  local labels=$1

  local nodesDescription=$(kubectl describe nodes -l $labels)
  local descriptionStatus=$?

  # If nodes description failed, k8s API might have been unresponsive, retry in 3 seconds
  if [[ ! $descriptionStatus -eq 0 ]]; then
    sleep 3
    nodesDescription=$(kubectl describe nodes -l $labels)
    descriptionStatus=$?
  fi

  # If nodes description was successful but no nodes were found, return -1
  if [[ $descriptionStatus -eq 0 && $nodesDescription == "" ]]; then
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

function getCurrentNodeCount() {
  local nodeCount=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-name $asgName --region $asgRegion | \
    jq '.AutoScalingGroups[].DesiredCapacity')

  if [[ $nodeCount == "" ]]; then
    # If awscli request fails, retry after 3 seconds
    sleep 3

    nodeCount=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-name $asgName --region $asgRegion | \
      jq '.AutoScalingGroups[].DesiredCapacity')
  fi

  return $nodeCount
}

function scaleUp() {
  local asgName=$1
  local asgRegion=$2
  local nodeToAddCount=$3

  aws autoscaling set-desired-capacity --auto-scaling-group-name $asgName \
          --desired-capacity $(expr $(getCurrentNodeCount) + $nodeToAddCount) --region $asgRegion

  if [[ ! $? -eq 0 ]]; then
    notifySlack "<!channel> Failed to scale up $asgName, hit maximum."
    return 1
  fi

  return 0
}

function scaleDown() {
  local asgName=$1
  local asgRegion=$2

  # Get the oldest node in the ASG
  local nodeName=$(kubectl get nodes -l aws.autoscaling.groupName=$asgName \
    --sort-by='{.metadata.creationTimestamp}' | awk '{ if(NR==2) print $1 }')

  local nodeId=$(kubectl describe node $nodeName | grep "ExternalID:" | awk '{ print $2 }')

  if [[ $nodeName == "" || $nodeId == "" ]]; then
    # If kube api requests fail, retry after 3 seconds
    sleep 3

    nodeName=$(kubectl get nodes -l aws.autoscaling.groupName=$asgName \
      --sort-by='{.metadata.creationTimestamp}' | awk '{ if(NR==2) print $1 }')

    nodeId=$(kubectl describe node $nodeName | grep "ExternalID:" | awk '{ print $2 }')

    if [[ $nodeName == "" || $nodeId == "" ]]; then
      notifySlack "<!channel> Failed to scale down $asgName, no nodes found."
      return 1
    fi
  fi

  aws autoscaling detach-instances --instance-ids $nodeId --auto-scaling-group-name $asgName \
    --should-decrement-desired-capacity --region $asgRegion

  if [[ ! $? -eq 0 ]]; then
    notifySlack "<!channel> Failed to detach $nodeId from $asgName, either hit minimum or node already detached."
  fi

  kubectl drain $nodeName --ignore-daemonsets --grace-period=90 --delete-local-data --force

  sleep 30

  aws ec2 terminate-instances --instance-ids $nodeId --region $asgRegion

  return 0
}

autoscalingNoWS=$(echo "$AUTOSCALING" | tr -d "[:space:]")
IFS=';' read -ra autoscalingArr <<< "$autoscalingNoWS"

RRAs=()

function main() {
  local index=0

  for autoscaler in "${autoscalingArr[@]}"; do
    IFS='|' read minRRA maxRRA asgName labels asgRegion <<< "$autoscaler"

    pendingPods=$(countPendingPods $asgName)
    runningPods=$(countRunningPods $asgName)
    requiredNodeCount=$(expr $(expr $pendingPods * $(getCurrentNodeCount)) / $runningPods)
    
    if [[ $? -gt 0 ]]; then
      echo "Pending pods. Scaling up $asgName."
      scaleUp $asgName $asgRegion $requiredNodeCount

      if [[ $? -eq 0 ]]; then
        notifySlack "Pending pods. Scaling up $asgName."
      fi

    else
      local currentRRA=$(getNodesRRA $labels)

      # Check that getNodesRRA returned a 1-3 digit number
      if [[ ${#currentRRA} -gt 0 && ${#currentRRA} -lt 4 ]]; then
        # Check that getNodesRRA didn't return -1 (no nodes found)
        if [[ ! $currentRRA -eq -1 ]]; then

          # Only print currentRRA when previous reading doesn't exist or is different
          if [[ -z ${RRAs[$index]} || (! -z ${RRAs[$index]} && ${RRAs[$index]} -ne $currentRRA) ]]; then
            echo "$currentRRA% RRA for $asgName."
            RRAs[$index]=$currentRRA
          fi

          if [[ $currentRRA -gt $maxRRA ]]; then
            echo "$currentRRA% > $maxRRA%. Scaling up $asgName."
            scaleUp $asgName $asgRegion 1

            if [[ $? -eq 0 ]]; then
              notifySlack "$currentRRA% > $maxRRA%. Scaling up $asgName."
            fi

          elif [[ $currentRRA -lt $minRRA ]]; then
            echo "$currentRRA% < $minRRA%. Scaling down $asgName."
            scaleDown $asgName $asgRegion

            if [[ $? -eq 0 ]]; then
              notifySlack "$currentRRA% < $minRRA%. Scaling down $asgName."
            fi
          fi

        else
          notifySlack "<!channel> ASG $asgName has no nodes."
          scaleUp $asgName $asgRegion 1

          if [[ $? -eq 0 ]]; then
            notifySlack "Pending pods. Scaling up $asgName."
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
