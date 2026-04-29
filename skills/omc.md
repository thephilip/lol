# omc skill — OpenShift must-gather inspector

`omc` reads OpenShift must-gather bundles offline. It mimics `oc` syntax
against a static snapshot. Always run `omc use <path>` first to load the
must-gather, then query it like a live cluster.

**Important — `omc` is not `oc`.** Supported flags for `omc get` are:
`-A`/`--all-namespaces`, `-n`/`--namespace`, `-o`/`--output` (json|yaml|wide|jsonpath|custom-columns),
`-l`/`--selector` (label selector), `--sort-by`, `--show-labels`, `--no-headers`.
**`--field-selector` is NOT supported** — use `grep` to filter output instead.
**`omc adm` does NOT support `top`** — CPU/memory usage is unavailable from a must-gather.
**`omc prometheus alertrule -o`** only accepts `json` or `yaml` (not `wide`).
Always use `--sort-by=.lastTimestamp` with `omc get events` to get time-ordered output.

## Setup

```bash
omc use /path/to/must-gather      # load a must-gather (required before anything else)
omc use                           # show currently loaded must-gather
```

---

## Cluster identity

```bash
omc get clusterversion version -o json
# Key fields: .spec.clusterID (external UUID), .status.history[0].version,
#             .spec.channel, .status.history[0].state (Completed|Partial)

omc get infrastructure cluster -o json
# Key fields: .status.platformStatus.type (AWS|GCP|Azure|BareMetal|None),
#             .status.infrastructureName, .status.apiServerURL,
#             .status.platformStatus.aws.region (platform-specific)

omc get network cluster -o json
# Key fields: .spec.networkType (OVNKubernetes|OpenShiftSDN),
#             .spec.clusterNetwork[0].cidr, .spec.serviceNetwork[0]
```

---

## Nodes

```bash
omc get nodes                              # list all nodes with status/roles/age
omc get nodes -o wide                      # includes IP, OS image, kernel, container runtime
omc describe node <name>                   # full node detail: conditions, capacity, taints, events
# Note: omc adm does NOT support 'top' — CPU/memory usage data is not available via omc

# Node conditions to check in describe output:
#   MemoryPressure, DiskPressure, PIDPressure → should all be False
#   Ready → must be True; False means the node is not schedulable
```

### Node capacity, allocatable, and SKU — JSON analysis

`omc get` does not support `--field-selector` or live metrics. For per-node
capacity/utilisation analysis, use `-o json` and pipe to `python3` or `jq`.
The `node.kubernetes.io/instance-type` label carries the cloud VM SKU.
`status.capacity` is the raw node total; `status.allocatable` is what
Kubernetes can schedule onto (capacity minus OS/kubelet overhead).

```bash
omc get nodes -o json | python3 -c "
import json, sys
nodes = json.load(sys.stdin)['items']
print(f'{'Node':<55} {'Role':<8} {'SKU':<22} {'CPU alloc':<12} {'Mem alloc GiB':<16} {'MemPressure'}')
print('-'*140)
for n in nodes:
    labels = n['metadata'].get('labels', {})
    role = ('master' if 'node-role.kubernetes.io/master' in labels or
            'node-role.kubernetes.io/control-plane' in labels
            else 'infra' if 'node-role.kubernetes.io/infra' in labels
            else 'worker')
    sku  = labels.get('node.kubernetes.io/instance-type', 'unknown')
    alloc = n['status'].get('allocatable', {})
    mem_ki = int(alloc.get('memory', '0Ki').replace('Ki',''))
    mp = next((c['status'] for c in n['status'].get('conditions',[])
               if c['type']=='MemoryPressure'), '?')
    print(f'{n[\"metadata\"][\"name\"]:<55} {role:<8} {sku:<22} {alloc.get(\"cpu\",\"?\"):<12} {mem_ki/1024/1024:<16.1f} {mp}')
"
```

### Pod resource requests per node

`omc adm top` is not available. Aggregate pod `requests` from JSON instead.
Memory values in pod specs use mixed suffixes: `Ki`, `Mi`, `Gi` (binary) and
`K`, `M`, `G` (decimal) and bare bytes — handle all of them:

```bash
omc get pods -A -o json | python3 -c "
import json, sys
from collections import defaultdict

def parse_cpu(s):
    if not s: return 0
    return int(s[:-1]) if s.endswith('m') else int(float(s)*1000)

def parse_mem(s):
    if not s: return 0
    s = str(s)
    for suf, mul in [('Ki',1024),('Mi',1024**2),('Gi',1024**3),
                     ('K',1000),('M',1000**2),('G',1000**3)]:
        if s.endswith(suf): return int(s[:-len(suf)])*mul
    try: return int(s)
    except: return 0

req = defaultdict(lambda: {'cpu':0,'mem':0})
for pod in json.load(sys.stdin)['items']:
    node = pod.get('spec',{}).get('nodeName')
    if not node: continue
    for c in pod.get('spec',{}).get('containers',[]):
        r = c.get('resources',{}).get('requests',{})
        req[node]['cpu'] += parse_cpu(r.get('cpu'))
        req[node]['mem'] += parse_mem(r.get('memory'))

print(f'{'Node':<55} {'CPU req (m)':<14} {'Mem req GiB'}')
print('-'*85)
for node, v in sorted(req.items()):
    print(f'{node:<55} {v[\"cpu\"]:<14} {v[\"mem\"]/1024**3:.2f}')
"
```

---

## Pods and workloads

```bash
omc get pods -n <namespace>                # list pods in namespace
omc get pods -A                            # all namespaces
omc get pods -A | grep -v Running          # find non-Running pods (omc has no --field-selector)
omc get pods -n <namespace> -o wide        # includes node placement and IPs

omc logs <pod> -n <namespace>              # current container logs
omc logs <pod> -n <namespace> --previous   # logs from previous (crashed) container
omc logs <pod> -n <namespace> -c <container>

omc describe pod <pod> -n <namespace>      # events, conditions, resource requests/limits
```

---

## Cluster operators

```bash
omc get clusteroperator                    # all operators — Available/Progressing/Degraded
omc get clusteroperator <name> -o yaml     # full status with conditions and messages

# A healthy operator shows: Available=True, Progressing=False, Degraded=False
# Degraded=True means something is wrong — check .status.conditions[].message
```

---

## Events

```bash
omc get events -n <namespace> --sort-by=.lastTimestamp    # events sorted by time
omc get events -A --sort-by=.lastTimestamp                 # all namespaces
omc get events -n <namespace> --sort-by=.lastTimestamp | grep BackOff   # filter with grep (no --field-selector)
omc get events -n <namespace> --sort-by=.lastTimestamp | grep Warning
```

---

## etcd

```bash
omc get pods -n openshift-etcd             # should be 3 pods (one per control plane node)
omc logs <etcd-pod> -n openshift-etcd -c etcd | grep -E "slow|took too long|leader|compacted"
omc get etcd cluster -o yaml               # etcd operator status and conditions

# Key log patterns:
#   "slow fdatasync" / "took too long"  → disk latency (I/O problem)
#   "lost leader"                        → quorum instability
#   "etcdHighFsyncDurations"             → Prometheus alert for high fsync
```

---

## Prometheus alerts

```bash
omc prometheus alertrule -s firing,pending         # only active alerts (default for lol alerts)
omc prometheus alertrule                           # all rules including inactive
omc prometheus alertrule -s firing,pending -o json # detail view (-o accepts json|yaml only, not wide)
omc prometheus alertgroup                          # grouped view

# Alert state: firing > pending > inactive
# Severity: critical > warning > info
```

---

## Machine API

```bash
omc get machines -n openshift-machine-api          # list machines and their phases
omc get machinesets -n openshift-machine-api       # desired vs ready replicas
omc get machineconfigpool                          # MCP status — Updated/Updating/Degraded
omc get machineconfig                              # list all MachineConfig objects
```

---

## Storage and PVCs

```bash
omc get pvc -n <namespace>                 # PersistentVolumeClaims — Bound/Pending/Lost
omc get pv                                 # PersistentVolumes cluster-wide
omc get storageclass                       # available storage classes
```

---

## Networking

```bash
omc get svc -n <namespace>                 # services and their cluster IPs / ports
omc get ingress -n <namespace>             # ingress rules
omc get route -n <namespace>               # OpenShift routes
omc get networkpolicy -n <namespace>       # network policies that may block traffic
```

---

## RBAC and config

```bash
omc get clusterrole <name> -o yaml
omc get rolebinding -n <namespace>
omc get configmap <name> -n <namespace> -o yaml
omc get secret <name> -n <namespace> -o yaml       # values are base64 encoded
```

---

## Common investigation workflows

### Operator is Degraded
```bash
omc get clusteroperator <name> -o yaml             # read .status.conditions[].message
omc get pods -n openshift-<name>                   # find crashed/pending pods
omc logs <pod> -n openshift-<name> --previous      # crash logs
omc get events -n openshift-<name> --sort-by=.lastTimestamp   # recent events
```

### Node NotReady
```bash
omc describe node <name>                           # check Conditions and Events sections
omc get pods -A -o wide | grep <name>                    # pods on this node (omc has no --field-selector)
omc logs <kubelet-pod> -n openshift-node --previous
```

### etcd issues
```bash
omc get pods -n openshift-etcd                     # all 3 should be Running
omc prometheus alertrule -s firing -g etcd         # any firing etcd alerts
omc logs <etcd-pod> -n openshift-etcd -c etcd | tail -200
```

### Pod CrashLoopBackOff
```bash
omc describe pod <pod> -n <ns>                     # check Exit Code and Last State
omc logs <pod> -n <ns> --previous                  # logs from before the crash
omc get events -n <ns> --sort-by=.lastTimestamp | grep <pod>   # no --field-selector; use grep
```
