# omc skill — OpenShift must-gather inspector

`omc` reads OpenShift must-gather bundles offline. It mimics `oc` syntax
against a static snapshot. Always run `omc use <path>` first to load the
must-gather, then query it like a live cluster.

**Important — `omc` is not `oc`.** Supported flags for `omc get` are:
`-A`/`--all-namespaces`, `-n`/`--namespace`, `-o`/`--output` (json|yaml|wide|jsonpath|custom-columns),
`-l`/`--selector` (label selector), `--sort-by`, `--show-labels`, `--no-headers`.
**`--field-selector` is NOT supported** — use `grep` to filter output instead.

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
omc adm top nodes                          # CPU/memory usage snapshot

# Node conditions to check in describe output:
#   MemoryPressure, DiskPressure, PIDPressure → should all be False
#   Ready → must be True; False means the node is not schedulable
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
omc get events -n <namespace>              # namespace events sorted by time
omc get events -A                          # all namespaces
omc get events -n <namespace> | grep BackOff     # omc has no --field-selector; use grep
omc get events -n <namespace> | grep Warning
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
omc prometheus alertrule -s firing,pending -o wide # includes labels and annotations
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
omc get events -n openshift-<name>                 # recent events
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
omc get events -n <ns> | grep <pod>              # omc has no --field-selector; use grep
```
