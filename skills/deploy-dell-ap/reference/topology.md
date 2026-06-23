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
   set so Longhorn uses the right replica count, and `LB_IP=<ingress-vip>` for a dedicated ingress VIP, e.g.
   `sudo CLUSTER_TYPE=multi-node LB_IP=<vip> BASE_DOMAIN=<domain> ./ap-tools install rke2 -tls-san <cluster-api-name>`.
2. Read the join token from the first server: `/var/lib/rancher/rke2/server/node-token`.
3. On each **additional** node, **join via the first server's node IP** (not the cluster name / VIP):
   - control-plane: `join server <FIRST-NODE-IP> <token> -tls-san <cluster-api-name>`
   - worker: `join agent <FIRST-NODE-IP> <token>`
4. Reuse the **same** `-registry` and `-tls-san` values that the first server used, on every node.
5. Then run `install ap-bundle` on a control-plane node **with `HOST_FQDN=<cluster-api-name>`**, and run
   `install-upgrade.sh` (it inherits the portal/orchestrator FQDNs from that `HOST_FQDN`).

## Rules
- Join only against a cluster of the **same RKE2 version** created by this tool. Joining a foreign
  cluster can cause configuration conflicts.
- **Join via the first server's node IP.** RKE2 does not add a node's own FQDN to the API cert, and the
  cluster/`-tls-san` name typically resolves to the **ingress VIP** (which does not serve the RKE2 API/
  supervisor port) or round-robins across nodes — both make the cluster name a poor join target. A node IP is
  unambiguous and always works.
- If the first install used `-registry`, every joined node must also pass `-registry`.

## The VIP is for ingress, not the API server
`ap-tools` provisions exactly one VIP: the **MetalLB ingress VIP** (`LB_IP`), which fronts the
**portal/orchestrator HTTPS**. It does **not** stand up an API-server load balancer. Consequences:
- `portal.*` / `orchestrator.*` / `mtls-*` DNS → the **ingress VIP** (`LB_IP`).
- the cluster / `-tls-san` name → the **node IPs** (DNS round-robin) or your own external API LB — never the
  ingress VIP. See [dns-and-certs.md](dns-and-certs.md) for the full DNS split.
- DNS round-robin is adequate API "HA" for labs (no health-checking — a lookup may hit a down node); for
  production API HA, front the API with a real load balancer (e.g. kube-vip/HAProxy) and use its VIP as the
  `-tls-san` target.

## Multi-node high availability
For a cluster that survives a single node failure without manual recovery, set these on the **first**
`install rke2` (and pass `NTP_SERVERS` on every node):
- **`LB_IP=<free-IP>`** — the dedicated floating **ingress** VIP in the nodes' L2 subnet (outside DHCP, not a
  node IP). MetalLB announces it from one node and fails it over to a surviving node within seconds. Point
  `portal.*`/`orchestrator.*` DNS at it. Left at its default it is the first node's own IP, lost while that node
  is down. (On single-node, `LB_IP` defaults to the host IP — correct, leave it.) `LB_VIP` is a deprecated
  alias for `LB_IP` and still honored, but use `LB_IP`.
- The tool also auto-configures Longhorn `nodeDownPodDeletionPolicy: delete-statefulset-pod` (StatefulSet
  pods on a dead node are deleted so replacements start automatically) and verifies the Longhorn CSI driver
  registered on every node — no manual steps after a node fails or rejoins.
