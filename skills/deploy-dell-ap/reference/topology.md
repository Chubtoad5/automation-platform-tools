# Topology — single vs multi-node

## Decision
- **Single-node** — one host runs everything. Simplest; right for labs, demos, and most proofs of
  concept. Start here if unsure.
- **Multi-node** — multiple control-plane (and optionally worker) nodes for high availability and
  capacity. Choose this when you need HA or more resources than one host provides. **Size each node at
  ≥ 20 GB RAM for a 3-node cluster** — 16 GB/node is insufficient (the Orchestrator install wedges at
  90-99% cluster memory). See [prerequisites.md](prerequisites.md).

## Single-node flow
`install rke2` → (optional `install harbor`) → `install ap-bundle -registry …` → run `install-upgrade.sh`.

## Multi-node flow
1. On the **first** server: `install rke2 -tls-san <cluster-api-name>`, with `CLUSTER_TYPE=multi-node`
   set so Longhorn uses the right replica count, e.g.
   `sudo CLUSTER_TYPE=multi-node BASE_DOMAIN=<domain> ./ap-tools install rke2 -tls-san <cluster-api-name>`.
2. Read the join token from the first server: `/var/lib/rancher/rke2/server/node-token`.
3. On each **additional** node:
   - control-plane: `join server <first-server-or-cluster-name> <token> -tls-san <cluster-api-name>`
   - worker: `join agent <first-server-or-cluster-name> <token>`
4. Reuse the **same** `-registry` and `-tls-san` values that the first server used, on every node.
5. Then run `install ap-bundle` on a control-plane node and run `install-upgrade.sh`.

## Rules
- Join only against a cluster of the **same RKE2 version** created by this tool. Joining a foreign
  cluster can cause configuration conflicts.
- Join via a **node IP or the `-tls-san` name** — RKE2 does not add a node's own FQDN to the API cert.
- If the first install used `-registry`, every joined node must also pass `-registry`.

## Multi-node high availability
For a cluster that survives a single node failure without manual recovery, set these on the **first**
`install rke2` (and pass `NTP_SERVERS` on every node):
- **`LB_VIP=<free-IP>`** — a dedicated floating ingress VIP in the nodes' L2 subnet (outside DHCP, not a
  node IP). MetalLB announces it from one node and fails it over to a surviving node within seconds. Point
  `portal.*`/`orchestrator.*` DNS at the VIP. Without it, the ingress VIP is a node IP and is lost while that
  node is down.
- The tool also auto-configures Longhorn `nodeDownPodDeletionPolicy: delete-statefulset-pod` (StatefulSet
  pods on a dead node are deleted so replacements start automatically) and verifies the Longhorn CSI driver
  registered on every node — no manual steps after a node fails or rejoins.
