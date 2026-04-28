# oc skill — OpenShift CLI (live cluster)

`oc` queries a **live** OpenShift cluster. Use it when you have direct
cluster access (e.g. via backplane) and need current state rather than
a point-in-time must-gather snapshot. Syntax is identical to `kubectl`
with OpenShift extensions added.

## omc vs oc — when to use which

| | `omc` | `oc` |
|---|---|---|
| Data source | Must-gather snapshot (static) | Live cluster (real-time) |
| Auth required | No | Yes (`oc login` or backplane) |
| Can exec into pods | No | Yes |
| Can modify cluster | No | Yes (with RBAC) |
| Works air-gapped | Yes | No |

---

## Authentication

```bash
oc login <api-url> --token=<token>     # token-based login
oc login <api-url> -u <user> -p <pass> # username/password

oc whoami                               # current user
oc whoami --show-token                  # current token (treat as secret)
oc config current-context              # active kubeconfig context
oc config get-contexts                 # all available contexts
oc config use-context <name>           # switch context

# Via ROSA/backplane (Red Hat internal)
ocm backplane login <cluster-id>       # authenticate via backplane
```

---

## Cluster identity

```bash
oc get clusterversion version -o json
# .spec.clusterID           external UUID
# .status.history[0].version  current version
# .spec.channel               update channel
# .status.conditions[]        update progress / errors

oc get infrastructure cluster -o json
# .status.platformStatus.type   AWS | GCP | Azure | BareMetal | None
# .status.infrastructureName    cluster infra name
# .status.apiServerURL          API server URL
# .status.platformStatus.aws.region  (platform-specific)

oc get network cluster -o json
# .spec.networkType        OVNKubernetes | OpenShiftSDN
# .spec.clusterNetwork[].cidr
# .spec.serviceNetwork[]
```

---

## Nodes

```bash
oc get nodes                            # all nodes — status, roles, age, version
oc get nodes -o wide                    # adds IP, OS image, kernel, container runtime
oc describe node <name>                 # conditions, capacity, allocatable, taints, events
oc adm top nodes                        # live CPU/memory usage

# Node conditions (check in describe output):
#   Ready=True      — node is schedulable
#   MemoryPressure  — should be False
#   DiskPressure    — should be False
#   PIDPressure     — should be False

oc debug node/<name>                    # open a root shell on a live node
# Inside debug shell:
#   chroot /host                        # switch to host filesystem
#   systemctl status kubelet            # kubelet service state
#   journalctl -u kubelet -n 100        # kubelet logs
#   crictl ps                           # running containers

oc adm drain <node> --ignore-daemonsets --delete-emptydir-data  # evacuate node
oc adm uncordon <node>                  # re-enable scheduling
```

---

## Pods and workloads

```bash
oc get pods -n <namespace>
oc get pods -A                          # all namespaces
oc get pods -A --field-selector status.phase=Failed
oc get pods -n <ns> -o wide            # node placement and IPs
oc get pods -n <ns> -w                 # watch for changes (live)

oc logs <pod> -n <ns>                  # current logs
oc logs <pod> -n <ns> --previous       # logs from crashed container
oc logs <pod> -n <ns> -c <container>   # specific container
oc logs <pod> -n <ns> --tail=100 -f    # follow live

oc exec -it <pod> -n <ns> -- /bin/bash # exec into pod
oc exec <pod> -n <ns> -- <command>     # run single command

oc describe pod <pod> -n <ns>          # full detail: events, conditions, resources
oc delete pod <pod> -n <ns>            # force pod restart
```

---

## Projects (namespaces)

```bash
oc projects                             # list all projects you have access to
oc project <name>                       # switch active project
oc new-project <name>                   # create a project
oc get project <name> -o yaml           # project metadata and annotations
```

---

## Cluster operators

```bash
oc get clusteroperator                  # all operators — Available/Progressing/Degraded
oc get co                               # shorthand
oc get co <name> -o yaml               # full status with conditions and messages
oc describe co <name>                   # formatted conditions and events

# Healthy state: Available=True, Progressing=False, Degraded=False
# Degraded=True → read .status.conditions[].message for root cause
```

---

## Events

```bash
oc get events -n <ns>                   # namespace events
oc get events -A                        # all namespaces
oc get events -n <ns> -w               # watch live
oc get events -n <ns> --sort-by='.lastTimestamp'
oc get events -n <ns> --field-selector reason=BackOff
oc get events -n <ns> --field-selector type=Warning
```

---

## Routes and services

```bash
oc get route -n <ns>                    # OpenShift routes (HTTP/HTTPS ingress)
oc get route -n <ns> -o wide           # includes hostname and TLS info
oc describe route <name> -n <ns>

oc get svc -n <ns>                      # services and cluster IPs
oc get endpoints -n <ns>               # service endpoint IPs (pod backends)

# Port-forward to reach a service locally
oc port-forward svc/<name> 8080:80 -n <ns>
oc port-forward pod/<name> 9090:9090 -n <ns>
```

---

## etcd (live)

```bash
oc get pods -n openshift-etcd          # should be 3 Running pods
oc get etcd cluster -o yaml            # etcd operator status and conditions
oc logs <etcd-pod> -n openshift-etcd -c etcd | grep -E "slow|took too long|leader"

# Check etcd member health via exec
oc exec -n openshift-etcd <etcd-pod> -c etcd -- \
  etcdctl endpoint health \
  --cacert /etc/kubernetes/static-pod-resources/etcd-certs/configmaps/etcd-serving-ca/ca-bundle.crt \
  --cert   /etc/kubernetes/static-pod-resources/etcd-certs/secrets/etcd-all-serving/etcd-serving-*.crt \
  --key    /etc/kubernetes/static-pod-resources/etcd-certs/secrets/etcd-all-serving/etcd-serving-*.key

# Key log patterns:
#   "slow fdatasync" / "took too long"  → disk latency
#   "lost leader" / "no leader"         → quorum issue
```

---

## Prometheus and alerts (live)

```bash
# Get the Prometheus route
oc get route prometheus-k8s -n openshift-monitoring

# Query alerts via Prometheus API (requires token)
TOKEN=$(oc whoami --show-token)
PROM_URL=$(oc get route prometheus-k8s -n openshift-monitoring -o jsonpath='{.spec.host}')

# Firing alerts
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://${PROM_URL}/api/v1/alerts" | jq '.data.alerts[] | select(.state=="firing")'

# Alert rules
curl -sk -H "Authorization: Bearer $TOKEN" \
  "https://${PROM_URL}/api/v1/rules" | jq '.data.groups[].rules[] | select(.type=="alerting")'
```

---

## Machine API

```bash
oc get machines -n openshift-machine-api        # machines and phases (Running|Provisioning|Failed)
oc get machinesets -n openshift-machine-api     # desired vs ready replicas
oc get machineconfigpool                        # MCPs — Updated/Updating/Degraded
oc get machineconfig                            # all MachineConfig objects
oc describe mcp <name>                          # MCP conditions and machine count

# Certificate approval (pending after node joins)
oc get csr                                      # list pending CSRs
oc adm certificate approve <csr-name>           # approve a CSR
oc get csr -o name | xargs oc adm certificate approve  # approve all pending
```

---

## RBAC and security

```bash
oc auth can-i <verb> <resource> -n <ns>         # check your own permissions
oc auth can-i <verb> <resource> --as <user>     # check another user's permissions
oc get rolebinding -n <ns>
oc get clusterrolebinding | grep <user-or-group>
oc get scc                                      # SecurityContextConstraints (OpenShift-specific)
oc describe scc <name>
```

---

## Certificates

```bash
oc get clusteroperator kube-apiserver -o yaml   # check for cert expiry warnings
oc get secret -n openshift-ingress              # ingress TLS cert
oc get secret -n openshift-kube-apiserver       # API server certs
oc -n openshift-config get secret <name> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
```

---

## Image streams and registry

```bash
oc get imagestream -n <ns>
oc get imagestreamtag -n <ns>
oc get configs.imageregistry.operator.openshift.io cluster -o yaml  # registry operator config
```

---

## oc adm — cluster administration

```bash
oc adm top nodes                        # node resource usage
oc adm top pods -n <ns>                # pod resource usage
oc adm node-logs <node> -u kubelet     # node journal logs (kubelet, crio, etc.)
oc adm node-logs <node> -u crio
oc adm must-gather                     # collect a must-gather bundle
oc adm must-gather --image=<custom>    # with a custom must-gather image
oc adm inspect co/<name>               # inspect a specific operator
oc adm release info                    # current release info and component versions
oc adm release info <version>          # info for a specific release
oc adm upgrade                         # show current upgrade status
oc adm upgrade --to <version>          # trigger an upgrade
```

---

## Common investigation workflows

### Operator is Degraded
```bash
oc get co <name> -o yaml               # read .status.conditions[].message
oc get pods -n openshift-<name>        # find crashed/pending pods
oc logs <pod> -n openshift-<name> --previous
oc get events -n openshift-<name> --sort-by='.lastTimestamp'
```

### Node NotReady
```bash
oc describe node <name>                # Conditions and Events sections
oc adm node-logs <name> -u kubelet --tail=100
oc get pods -A --field-selector spec.nodeName=<name>   # pods on this node
oc debug node/<name>                   # root shell on the node
```

### Pod CrashLoopBackOff
```bash
oc describe pod <pod> -n <ns>          # Exit Code and Last State
oc logs <pod> -n <ns> --previous       # logs before the crash
oc get events -n <ns> --field-selector involvedObject.name=<pod>
```

### Upgrade stuck or failing
```bash
oc get clusterversion version -o yaml  # conditions and history
oc get co                              # any operators blocking the upgrade
oc adm upgrade                         # current upgrade status and available versions
oc get mcp                             # MachineConfigPool — nodes may be updating
```

### etcd unhealthy
```bash
oc get pods -n openshift-etcd
oc get etcd cluster -o yaml
oc prometheus alertrule -s firing 2>/dev/null | grep -i etcd  # via omc if available
oc logs <etcd-pod> -n openshift-etcd -c etcd | grep -E "slow|leader|compacted" | tail -50
```
