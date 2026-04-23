NAME=pdb-blocking-upgrade
SEVERITY=warning
SUMMARY=A PodDisruptionBudget alert indicates a PDB is at its disruption limit and will block node drain
PATTERN=PodDisruptionBudgetAtLimit
PATTERN=PodDisruptionBudgetLimit
REMEDIATION=Identify the blocking PDB and its owner workload. Options: (1) coordinate a maintenance window and temporarily patch the PDB, (2) scale the deployment to satisfy the PDB budget before draining, (3) if the PDB is in an openshift-* namespace it is usually self-resolving once the upgrade proceeds.
