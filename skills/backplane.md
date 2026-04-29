# backplane skill — live cluster access for managed OpenShift

`ocm backplane` provides authenticated tunnel access to ROSA and OSD managed
clusters without requiring direct cluster credentials. After login, standard
`oc` commands work against the live cluster via the tunnel.

**When to use backplane vs alternatives:**
- **backplane** — cluster is up and reachable; need live state, logs, or to run managed scripts
- **must-gather + omc** — cluster is degraded/unreachable, or need a safe offline snapshot
- **OCM API** — need subscription metadata, service logs, upgrade policies, limited support reasons

---

## Authentication

```bash
ocm backplane login <cluster-id>         # cluster-id = OCM internal ID or external UUID
ocm backplane login <cluster-id> --manager   # HyperShift/ROSA HCP: log into management cluster
ocm backplane status                     # show current session info (cluster, user, expiry)
ocm backplane logout                     # end the session and unset KUBECONFIG
```

After `login`, backplane sets `KUBECONFIG` automatically. All subsequent `oc`
commands target the live cluster for the duration of the session.

### Resolve cluster-id from a must-gather external UUID
```bash
ocm get /api/clusters_mgmt/v1/clusters \
  --parameter "search=external_id='<uuid>'" \
  --parameter size=1 | jq -r '.items[0].id'
```

---

## Console and tunnelling

```bash
ocm backplane console          # open the cluster web console in the default browser
ocm backplane tunnel           # create a local kubectl-proxy-style tunnel (for port-forwarding)
```

---

## Cloud credentials

```bash
ocm backplane cloud credentials           # print temporary cloud provider credentials
ocm backplane cloud credentials -o env    # print as shell export statements (AWS_*, etc.)
```

Useful for checking IAM roles, S3 bucket access, or cloud-side resource state
when the cluster issue may have a cloud-layer cause.

---

## Managed scripts

Managed scripts are curated, SRE-reviewed scripts from
`github.com/openshift/managed-scripts`. They run inside a backplane session
and are the approved way to perform common support tasks on managed clusters.

```bash
ocm backplane script list                          # list all available scripts
ocm backplane script list | grep <keyword>         # filter by keyword
ocm backplane script describe <script-name>        # show what a script does and its parameters
ocm backplane script run <script-name>             # run a script against the active cluster
ocm backplane script run <script-name> -- <args>   # pass arguments to the script
```

### Common script categories

| Category | What to look for |
|---|---|
| Log collection | scripts that dump operator/component logs |
| etcd | member health, defrag, compaction, snapshot size |
| Node debugging | journal logs, kubelet state, disk/memory pressure |
| Certificate inspection | cert expiry, SAN validation |
| Network diagnostics | connectivity checks, OVN/SDN state |
| RBAC / SCC | permission audits |

---

## Using `oc` after backplane login

Once logged in, standard `oc` commands work against the live cluster:

```bash
oc get nodes                                      # live node state
oc get pods -A | grep -v Running                  # non-running pods
oc describe node <name>                           # conditions, capacity, taints
oc adm top nodes                                  # live CPU/memory usage (requires metrics-server)
oc adm top pods -A --sort-by=memory               # top memory consumers
oc get events -A --sort-by=.lastTimestamp         # recent cluster events
oc logs <pod> -n <namespace> --previous           # previous container logs
oc adm must-gather                                # collect must-gather from live cluster
```

### Node resource usage (live)
```bash
oc adm top nodes                         # summary per node
oc describe node <name>                  # Allocated resources section shows actual utilisation
```

The `Allocated resources` section in `oc describe node` shows requested vs
allocatable CPU and memory — more useful than `top` for capacity planning.

---

## Common investigation workflows

### Live cluster — general health check
```bash
ocm backplane login <cluster-id>
oc get nodes                             # all Ready?
oc get co                                # all operators Available=True, Degraded=False?
oc get pods -A | grep -vE 'Running|Completed'   # any stuck pods?
oc get events -A --sort-by=.lastTimestamp | tail -30
```

### Memory pressure investigation (live)
```bash
oc adm top nodes                                         # which nodes are high?
oc adm top pods -A --sort-by=memory | head -20           # top consumers
oc describe node <name>                                  # Allocated resources + Conditions
oc get events -A --sort-by=.lastTimestamp | grep -iE 'evict|OOM|kill|pressure'
```

### etcd health (live)
```bash
oc get pods -n openshift-etcd                            # all 3 Running?
oc get etcd cluster -o yaml                              # operator conditions
oc logs <etcd-pod> -n openshift-etcd -c etcd | grep -E "slow|took too long|lost leader"
# Or use a managed script:
ocm backplane script list | grep etcd
ocm backplane script run <etcd-health-script>
```

### Operator degraded (live)
```bash
oc get co <name> -o yaml                                 # .status.conditions[].message
oc get pods -n openshift-<name> | grep -v Running        # crashed pods?
oc logs <pod> -n openshift-<name> --previous             # crash logs
oc get events -n openshift-<name> --sort-by=.lastTimestamp
```

### Collect must-gather from live cluster (via backplane)
```bash
ocm backplane login <cluster-id>
oc adm must-gather --dest-dir=/tmp/mg-$(date +%Y%m%d)
# Then load it into lol:
lol use /tmp/mg-<date>/must-gather.local.*
```

---

## HyperShift / ROSA HCP specifics

HyperShift clusters have a split architecture: the control plane runs in a
management cluster, worker nodes run in the customer's cloud account.

```bash
# Login to the hosted cluster (data plane — worker nodes)
ocm backplane login <cluster-id>

# Login to the management cluster (control plane — etcd, API server, etc.)
ocm backplane login <cluster-id> --manager

# The HCP namespace on the management cluster contains all control plane pods:
oc get pods -n <hcp-namespace>        # hcp-namespace from OCM: .hypershift.hcp_namespace
```

When the customer reports API or control-plane issues on ROSA HCP, always
check the management cluster view — the hosted cluster view only shows
worker-side symptoms.
