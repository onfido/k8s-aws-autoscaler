#!/bin/bash

notifySlack() {
  if [ -z "$SLACK_HOOK" ]; then
    return 0
  fi

  curl -s --retry 3 --retry-delay 3 -X POST --data-urlencode 'payload={"text": "'"$1"'"}' $SLACK_HOOK > /dev/null
}

rotateNodes() {
  asgName=$1
  asgRegion=$2

  # Get number of nodes older than MAX_AGE_DAYS in the current ASG
  oldNodes=$(kubectl get nodes -l aws.autoscaling.groupName=$asgName 2> /dev/null | \
    grep -E '([a-zA-Z0-9,.-]+\s+){2}[0-9]+d.*' | sed 's/d//g' | \
    awk -v days=$MAX_AGE_DAYS '$3 > days { print }' | wc -l)

  if [[ $oldNodes != "" && $oldNodes -gt 0 ]]; then
    currentAsgNodes=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-name $asgName --region $asgRegion | \
      jq '.AutoScalingGroups[].DesiredCapacity')

    if [[ $currentAsgNodes != "" ]]; then
      desiredNodes=$(expr $currentAsgNodes + $oldNodes 2> /dev/null)

      if [[ $desiredNodes != "" && $desiredNodes -gt 0 ]]; then
        aws autoscaling set-desired-capacity --auto-scaling-group-name $asgName \
          --desired-capacity $desiredNodes --region $asgRegion

        if [[ $? -eq 0 ]]; then
          echo "`date` -- Found $oldNodes nodes older than $MAX_AGE_DAYS days in $asgName. Scaled up $oldNodes and waiting for scale down..."
          notifySlack "Found $oldNodes nodes older than $MAX_AGE_DAYS days in $asgName. Scaled up $oldNodes and waiting for scale down..."
        else
          echo "`date` -- Found $oldNodes nodes older than $MAX_AGE_DAYS days in $asgName. Failed to scale up for nodes rotation, hit maximum."
          notifySlack "Found $oldNodes nodes older than $MAX_AGE_DAYS days in $asgName. Failed to scale up for nodes rotation, hit maximum."
        fi
      fi
    fi
  else
    echo "`date` -- No old nodes found in $asgName."
  fi

  return 0
}

autoscalingGroupsNoWs=$(echo "$AUTOSCALING_GROUPS" | tr -d "[:space:]")
IFS=';' read -ra autoscalingGroups <<< "$autoscalingGroupsNoWs"

for asg in "${autoscalingGroups[@]}"; do
  IFS='|' read asgName asgRegion <<< "$asg"

  rotateNodes $asgName $asgRegion
done
