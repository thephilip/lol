#!/usr/bin/env bash
# DESC: node and machine status — NotReady nodes, MCP degradation, node events

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

MG_PATH="$(resolve_mg_path "${1:-}")" || exit 2
FINDINGS=0

omc_use "$MG_PATH"

# ── Node Status ────────────────────────────────────────────────────────────
header "Node Status"
node_output="$(omc get nodes 2>&1)"
echo "$node_output"

# Column 2 is STATUS; filter rows where it isn't exactly "Ready"
not_ready="$(echo "$node_output" | awk 'NR>1 && $2!="Ready"')" || true
if [[ -n "$not_ready" ]]; then
  finding "Nodes not in Ready state:"
  echo "$not_ready"
  ((FINDINGS++)) || true
  match_signatures "node" "$not_ready"
else
  ok "All nodes Ready"
fi

# ── Machine Status ─────────────────────────────────────────────────────────
header "Machine Status (openshift-machine-api)"
machine_output="$(omc get machines -n openshift-machine-api 2>&1)"
echo "$machine_output"

bad_machines="$(echo "$machine_output" | grep -vE '^NAME|Running|^$')" || true
if [[ -n "$bad_machines" ]]; then
  finding "Machines not in Running phase:"
  echo "$bad_machines"
  ((FINDINGS++)) || true
  match_signatures "node" "$bad_machines"
else
  ok "All machines Running"
fi

# ── MachineConfigPools ─────────────────────────────────────────────────────
header "MachineConfigPools"
mcp_output="$(omc get mcp 2>&1)"
echo "$mcp_output"

# Columns: NAME CONFIG UPDATED UPDATING DEGRADED MACHINECOUNT ...
degraded_mcp="$(echo "$mcp_output" | awk 'NR>1 && $5=="True"')" || true
if [[ -n "$degraded_mcp" ]]; then
  finding "Degraded MachineConfigPools:"
  echo "$degraded_mcp"
  ((FINDINGS++)) || true
  match_signatures "node" "$degraded_mcp"
else
  ok "No degraded MCPs"
fi

# ── Notable Node Events ────────────────────────────────────────────────────
header "Node Warning Events"
events_output="$(omc get events -A 2>&1)" || events_output=""
node_events="$(echo "$events_output" | grep -iE 'NotReady|OOMKill|Evict|DiskPressure|MemoryPressure|PIDPressure|NetworkPlugin' | head -20)" || true

if [[ -n "$node_events" ]]; then
  finding "Notable node events (first 20):"
  echo "$node_events"
  ((FINDINGS++)) || true
  match_signatures "node" "$node_events"
else
  ok "No notable node events"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
[[ $FINDINGS -eq 0 ]] && ok "Nodes check passed — no issues found"
exit $((FINDINGS > 0 ? 1 : 0))
