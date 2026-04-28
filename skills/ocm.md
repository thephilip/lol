# ocm skill — OpenShift Cluster Manager CLI

`ocm` queries the OpenShift Cluster Manager API at `api.openshift.com`.
It requires an active login. All `lol` OCM commands use this CLI under the hood.

## Authentication

```bash
ocm login --use-auth-code      # browser-based SSO login (recommended)
ocm whoami                     # verify current session and identity
ocm token                      # print the current bearer token (treat as a secret)
```

---

## Cluster lookup

The OCM API uses two distinct cluster identifiers:
- **External ID** — the UUID in ClusterVersion (`spec.clusterID`), used in customer-facing contexts
- **Internal ID** — OCM's own opaque ID (e.g. `2od50p9f7los3o32vi60i1d1ln7fg3j2`), required for most API paths

```bash
# Look up by external UUID
ocm get /api/clusters_mgmt/v1/clusters \
  --parameter "search=external_id='<uuid>'" \
  --parameter size=1

# Look up by name
ocm get /api/clusters_mgmt/v1/clusters \
  --parameter "search=name='<cluster-name>'" \
  --parameter size=1

# Get full cluster object by internal ID
ocm get /api/clusters_mgmt/v1/clusters/<internal-id>
```

### Resolve internal ID from external UUID (jq one-liner)
```bash
ocm get /api/clusters_mgmt/v1/clusters \
  --parameter "search=external_id='<uuid>'" \
  --parameter size=1 | jq -r '.items[0].id'
```

---

## Key cluster fields

```json
{
  "id":                  "<internal-ocm-id>",
  "external_id":         "<cluster-uuid>",
  "name":                "my-cluster",
  "openshift_version":   "4.18.5",
  "status": { "state":  "ready" },
  "product": { "id":    "rosa" },
  "cloud_provider": { "id": "aws" },
  "region": { "id":     "us-east-1" },
  "multi_az":            true,
  "ccs": { "enabled":   true },
  "hypershift": {
    "enabled":            true,
    "management_cluster": "hs-mc-abcdef",
    "hcp_namespace":      "ocm-production-abc123"
  },
  "aws": {
    "private_link":       false,
    "sts": { "enabled":  true }
  },
  "api":     { "url":    "https://api.<name>.<domain>:443" },
  "console": { "url":    "https://console-openshift-console.apps.<name>.<domain>" },
  "nodes": { "master": 3, "infra": 2, "compute": 3 },
  "creation_timestamp":  "2026-01-15T10:30:00Z"
}
```

---

## Service logs

Service log entries are posted by Red Hat automation and SREs for managed clusters.
They are the first place to check for recent automated actions or known issues.

```bash
# Fetch recent service log entries (newest first)
ocm get /api/service_logs/v1/clusters/cluster_logs \
  --parameter "cluster_uuid=<external-uuid>" \
  --parameter "orderBy=timestamp desc" \
  --parameter "size=20"

# Filter to a specific severity
ocm get /api/service_logs/v1/clusters/cluster_logs \
  --parameter "cluster_uuid=<external-uuid>" \
  --parameter "search=severity='Warning'" \
  --parameter "orderBy=timestamp desc"
```

### Key service log fields
```json
{
  "severity":     "Info | Warning | Error | Fatal",
  "service_name": "SREManualAction | Autoscaler | ...",
  "summary":      "Human-readable one-line summary",
  "description":  "Full detail",
  "timestamp":    "2026-04-15T10:30:00Z"
}
```

---

## Limited support

```bash
# Check if cluster has limited support reasons (needs internal ID)
ocm get /api/clusters_mgmt/v1/clusters/<internal-id>/limited_support_reasons

# .total == 0 → full support
# .total > 0  → limited; read .items[].summary and .items[].details
```

---

## Upgrade policies

```bash
ocm get /api/clusters_mgmt/v1/clusters/<internal-id>/upgrade_policies

# Key fields per policy:
#   .schedule_type    (Manual|Automatic)
#   .version          (target version)
#   .next_run         (next scheduled upgrade time)
#   .enable           (whether the policy is active)
```

---

## Addons

```bash
ocm get /api/clusters_mgmt/v1/clusters/<internal-id>/addons

# Key fields per addon:
#   .id               (e.g. "managed-odh", "rhods", "acm")
#   .state            (ready|failed|installing)
#   .operator_version
```

---

## Search syntax

The `search` parameter uses SQL-like syntax:

```bash
# String equality
--parameter "search=name='my-cluster'"

# Partial match
--parameter "search=name like 'prod%'"

# Boolean
--parameter "search=ccs.enabled = true"
--parameter "search=hypershift.enabled = true"

# Multiple conditions
--parameter "search=cloud_provider.id = 'aws' AND region.id = 'us-east-1'"

# State filter
--parameter "search=status.state = 'ready'"
```

---

## Pagination

```bash
# Default page size is usually 100. For large result sets:
--parameter "size=500"
--parameter "page=2"

# Total count is in .total; current page size is in .size
```

---

## Common investigation workflows

### Start from an external UUID (must-gather cluster ID)
```bash
# 1. Resolve internal ID
internal_id=$(ocm get /api/clusters_mgmt/v1/clusters \
  --parameter "search=external_id='<uuid>'" \
  --parameter size=1 | jq -r '.items[0].id')

# 2. Check basic status
ocm get /api/clusters_mgmt/v1/clusters/$internal_id | jq '{name,version:.openshift_version,state:.status.state}'

# 3. Check service log
ocm get /api/service_logs/v1/clusters/cluster_logs \
  --parameter "cluster_uuid=<uuid>" \
  --parameter "orderBy=timestamp desc" \
  --parameter size=10 | jq '.items[] | "[\(.timestamp[0:19])] [\(.severity)] \(.summary)"'

# 4. Check limited support
ocm get /api/clusters_mgmt/v1/clusters/$internal_id/limited_support_reasons | jq '{total, reasons:.items[]?|{summary,details}}'
```

### Find all clusters in limited support for an org
```bash
ocm get /api/clusters_mgmt/v1/clusters \
  --parameter "search=status.state != 'uninstalling'" \
  --parameter size=500 | \
  jq '[.items[] | select(.status.limited_support_reason_count > 0) | {name, id, external_id}]'
```
