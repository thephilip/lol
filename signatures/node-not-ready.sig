NAME=node-not-ready
SEVERITY=critical
SUMMARY=One or more nodes are in NotReady state — workloads will be evicted and rescheduled
PATTERN=NotReady
PATTERN=KubeletNotReady
PATTERN=node.*not.*ready
REMEDIATION=Check kubelet status on affected node(s). Look for disk pressure, memory pressure, or network issues in node conditions. Review recent events on the node. Check if the node is reachable and if the kubelet service is running.
