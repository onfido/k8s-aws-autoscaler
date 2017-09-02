## AWS Kubernetes nodes autoscaler

#### Autoscaling process (`autoscale.sh`, `deploy-autoscaler.yml`):
- Loops through AWS ASG defined in `AUTOSCALING` (env var), every `INTERVAL` (env var, default 180) seconds.
- Will scale up (increase desired nodes on an ASG) if:
  - Pods assigned to that ASG are _Pending_ for more than 2min.
  - Current total RRA is bigger than maximum allowed RRA (from `AUTOSCALING` env var) on the ASG nodes.
- Will scale down (detach + drain + terminate oldest node in ASG) if:
  - Current total RRA is smaller than minimum allowed RRA (from `AUTOSCALING` env var) on the ASG nodes.
- Every scale up/scale down event or getNodesRRA failed event will notify Slack if the `SLACK_HOOK` env var is set.

#### Nodes rotation (`rotate-nodes.sh`, `deploy-rotate-cron.yml`):
Every 6h (cron schedule) it loops through the defined `AUTOSCALING_GROUPS` (env var) and gets the number of nodes older than `MAX_AGE_DAYS` (env var, default 2) days and scales up the ASG by that number. The autoscaler will then scale down the ASG back to the desired capacity starting with the oldest nodes.

### Requirements

- https://github.com/onfido/aws-to-k8s-labels must be running on the cluster.
- Pods running on the ASG(s) in `AUTOSCALING` (env var) must have node selectors set.
- The ASG(s) in `AUTOSCALING` (env var) must have Instance Protection set to _Protect From Scale In_ so the autoscaler can control which node gets drained+terminated in a scale down event.
- ASG(s) cannot have `|` or `;` symbols in name(s).
- The K8s master nodes AWS role policy must allow the following actions:
```
autoscaling:DescribeAutoScalingGroups,
autoscaling:SetDesiredCapacity,
autoscaling:DetachInstances,
ec2:TerminateInstances
```

### Env vars

#### Autoscaler (`deploy-autoscaler.yml`)
- `INTERVAL` (required, default 180): Seconds between checks in the autoscaling process described above
- `AUTOSCALING` (required): Contains min/max RRA(s) and ASG(s) in the following pattern:
  - single ASG: `<minRRA>|<maxRRA>|<ASG name>|<node labels>|<ASG region>`
  - multiple ASGs: `<minRRA>|<maxRRA>|<ASG1 name>|<node labels>|<ASG1 region>;<minRRA>|<maxRRA>|<ASG2 name>|<node labels>|<ASG2 region>`
  - e.g. `30|70|General-ASG|Group=General|eu-west-1;40|60|GPU-ASG|Group=Research,GroupType=GPU|eu-west-1` or check `deploy.yml`
    - `<node labels>` like `Group=General` are currently used in the calculations of the RRA for node groups and are very useful when we have 2+ ASGs per node group, of which we only want to scale one of them (the other ASGs might be for Spot instances with static number of nodes).
- `SLACK_HOOK` (optional): Slack incoming webhook for event notifications

#### Nodes rotation (`deploy-rotate-cron.yml`)
- `MAX_AGE_DAYS` (required, default 2): Max age of nodes in days
  - e.g. If set to 2, the rotate-nodes script will check for nodes older than 2 days. If it finds X old nodes, it will scale up the ASG by X and then the autoscaler will (safely) scale down X times. The scale down events always pick the oldest instances in the ASG.
- `AUTOSCALING_GROUPS` (required): Contains ASG(s) and AWS region(s) in the following pattern:
  - single ASG: `<ASG name>|<ASG region>`
  - multiple ASGs: `<ASG1 name>|<ASG1 region>;<ASG2 name>|<ASG2 region>`
  - e.g. `General-ASG|eu-west-1;GPU-ASG|eu-west-1`
- `SLACK_HOOK` (optional): Slack incoming webhook for event notifications

### Deployment

```
kubectl --context CONTEXT -n kube-system apply -f deploy-autoscaler.yml
kubectl --context CONTEXT -n kube-system apply -f deploy-rotate-cron.yml
```

### Notes

- Supports multiple, single-AZ or multi-AZ AWS ASG

**RRA** - Requested Resources Average `(requested CPU + requested RAM) / 2`
<br>**ASG** - Auto Scaling Group
