#!/usr/bin/env bash
# DESC: etcd health — operator status, pod health, disk latency, firing alerts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

MG_PATH="$(resolve_mg_path "${1:-}")" || exit 2
FINDINGS=0

omc_use "$MG_PATH"

# ── Cluster Operator ───────────────────────────────────────────────────────
header "etcd Cluster Operator"
co_output="$(omc get co etcd 2>&1)"
echo "$co_output"

# Columns: NAME VERSION AVAILABLE PROGRESSING DEGRADED SINCE MESSAGE
if echo "$co_output" | awk 'NR>1 && /^etcd/ { if ($3!="True" || $5!="False") exit 1 }'; then
  ok "etcd CO available and not degraded"
else
  finding "etcd cluster operator is not healthy (check AVAILABLE/DEGRADED columns)"
  ((FINDINGS++)) || true
  match_signatures "etcd" "$co_output"
fi

# ── Pod Status ─────────────────────────────────────────────────────────────
header "etcd Pods (openshift-etcd)"
pod_output="$(omc get pods -n openshift-etcd 2>&1)"
echo "$pod_output"

not_running="$(echo "$pod_output" | grep -vE '^NAME|Running|Completed|^$')" || true
if [[ -n "$not_running" ]]; then
  finding "etcd pods not in Running/Completed state"
  ((FINDINGS++)) || true
  match_signatures "etcd" "$not_running"
else
  ok "All etcd pods running"
fi

# ── Firing Alerts ──────────────────────────────────────────────────────────
header "Firing etcd Alerts"
all_alerts="$(omc get alerts -A 2>&1)" || all_alerts=""
etcd_alerts="$(echo "$all_alerts" | grep -i 'etcd')" || true

if [[ -n "$etcd_alerts" ]]; then
  finding "Firing etcd-related alerts:"
  echo "$etcd_alerts"
  ((FINDINGS++)) || true
  match_signatures "etcd" "$etcd_alerts"
else
  ok "No firing etcd alerts"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
[[ $FINDINGS -eq 0 ]] && ok "etcd check passed — no issues found"
exit $((FINDINGS > 0 ? 1 : 0))
