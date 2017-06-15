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
  - single ASG: `<minRRA>|<maxRRA>|<ASG name>|<ASG region>`
  - multiple ASGs: `<minRRA>|<maxRRA>|<ASG1 name>|<ASG1 region>;<minRRA>|<maxRRA>|<ASG2 name>|<ASG2 region>`
  - e.g. `30|70|General-ASG|eu-west-1;40|60|GPU-ASG|eu-west-1`
- `SLACK_HOOK` (optional): Slack incoming webhook for event notifications
- `ROTATE_NODES` (optional): Number of days when instances should be (safely) rotated.
  - e.g. If set to 2, the autoscaling script will check every 12h for nodes older than 2 days. If it finds X old nodes, it will scale up by X and then (safely) scale down X times. The scale down events always pick the oldest instances in the ASGs.

### Deployment

```
kubectl --context CONTEXT -n kube-system apply -f deploy.yml
```

### Notes

- Supports multiple, single-AZ or multi-AZ AWS ASG

**RRA** - Requested Resources Average `(requested CPU + requested RAM) / 2`
<br>**ASG** - Auto Scaling Group
