## AWS Kubernetes nodes autoscaler

Autoscaling process (`autoscale.sh`):
- Loops through AWS ASG defined in `AUTOSCALING` (env var), every `INTERVAL` (env var) seconds.
- Will scale up (increase desired nodes on an ASG) if:
  - Pods assigned to that ASG are _Pending_ for more than 2min.
  - Current total RRA is bigger than maximum allowed RRA (from `AUTOSCALING` env var) on the ASG nodes.
- Will scale down (detach + drain + terminate oldest node in ASG) if:
  - Current total RRA is smaller than minimum allowed RRA (from `AUTOSCALING` env var) on the ASG nodes.
- Every scale up/scale down event or getNodesRRA failed event will notify Slack if the `SLACK_HOOK` env var is set.

This Pod runs in the `kube-system` namespace on k8s master nodes.

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

- `INTERVAL` (required): Seconds between checks in the autoscaling process described above (120 - 300 recommended)
- `AUTOSCALING` (required): Contains min/max RRA(s) and ASG(s) in the following pattern:
  - single ASG: `<minRRA>|<maxRRA>|<ASG name>|<node labels>|<ASG region>`
  - multiple ASGs: `<minRRA>|<maxRRA>|<ASG1 name>|<node labels>|<ASG1 region>;<minRRA>|<maxRRA>|<ASG2 name>|<node labels>|<ASG2 region>`
  - e.g. `30|70|General-ASG|Group=General|eu-west-1;40|60|GPU-ASG|Group=Research,GroupType=GPU|eu-west-1` or check `deploy.yml`
    - `<node labels>` like `Group=General` are currently used in the calculations of the RRA for node groups and are very useful when we have 2+ ASGs per node group, of which we only want to scale one of them (the other ASGs might be for Spot instances with static number of nodes).
- `SLACK_HOOK` (optional): Slack incoming webhook for event notifications

### Deployment

```
kubectl --context CONTEXT -n kube-system apply -f deploy.yml
```

### Notes

- Supports multiple, single-AZ or multi-AZ AWS ASG

**RRA** - Requested Resources Average `(requested CPU + requested RAM) / 2`
<br>**ASG** - Auto Scaling Group
