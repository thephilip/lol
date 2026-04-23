#!/usr/bin/env bash
# DESC: PodDisruptionBudgets — identify any with 0 allowed disruptions (upgrade blockers)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

MG_PATH="$(resolve_mg_path "${1:-}")" || exit 2
FINDINGS=0

omc_use "$MG_PATH"

# ── All PDBs ───────────────────────────────────────────────────────────────
header "PodDisruptionBudgets (all namespaces)"
pdb_output="$(omc get pdb -A 2>&1)"
echo "$pdb_output"

# Columns: NAMESPACE NAME MIN-AVAILABLE MAX-UNAVAILABLE ALLOWED-DISRUPTIONS AGE
# ALLOWED DISRUPTIONS = 0 means node drain will be blocked during upgrades.
blocking="$(echo "$pdb_output" | awk 'NR>1 && $5=="0"')" || true
if [[ -n "$blocking" ]]; then
  finding "PDBs with 0 allowed disruptions — will block node drain/upgrade:"
  echo "$blocking"
  ((FINDINGS++)) || true
  match_signatures "pdb" "$blocking"
else
  ok "No PDBs with 0 allowed disruptions"
fi

# ── Customer namespace PDBs ────────────────────────────────────────────────
header "PDBs in customer namespaces"
customer_pdbs="$(echo "$pdb_output" | awk 'NR>1 && $1 !~ /^openshift-|^kube-|^default$/')" || true
if [[ -n "$customer_pdbs" ]]; then
  info "Customer-namespace PDBs (review if upgrade is planned):"
  echo "$customer_pdbs"
else
  ok "No PDBs in customer namespaces"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo
[[ $FINDINGS -eq 0 ]] && ok "PDB check passed — no upgrade-blocking PDBs found"
exit $((FINDINGS > 0 ? 1 : 0))
