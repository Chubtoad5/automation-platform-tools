# Prerequisites (what you provide)

This skill does **not** create infrastructure. You provision the host(s) yourself on whatever platform
you use — vSphere, Proxmox, KVM/libvirt, a public cloud, or bare metal. The requirements are the same
everywhere.

## Per-host sizing (Automation Platform / RKE2 host)

| Resource | Minimum | Notes |
|:--|:--|:--|
| CPU | **18 vCPU** | DAP 2.1.1.0's own floor is `12000m`; 18 is the supported spec. |
| RAM (single-node) | **36 GB** | Provision 36, not 34. RKE2 + platform services reserve ~2 GB, and the DAP bundle's pre-flight measures *Kubernetes-allocatable* capacity — `ap-tools` gates on **34 GB allocatable**, which a 36 GB host satisfies and a 34 GB host does not. |
| RAM (multi-node, per node) | **≥ 20 GB** for a 3-node cluster | The platform footprint requests **~46 GB cluster-wide**. **16 GB/node is insufficient** — a 16 GB × 3 cluster saturates to 90-99% memory and the Orchestrator install wedges mid-convergence (services can't pass liveness). 20 GB/node (validated) leaves ~84% headroom and converges cleanly. Fewer than 3 nodes need more per node. |
| All-in-one single-node | **20 vCPU / 40 GB / 1 TB** | Only when co-locating a local Harbor + SeaweedFS with RKE2/DAP on one host. The extra CPU/RAM covers the registry + storage services; the larger disk holds the locally-pushed image set (`SKIP_IMAGES_LOADER=false`). |
| Disk | **850 GB SSD** | **1 TB strongly recommended.** DAP 2.1.1.0 enforces `REQUIRED_DISK_SPACE=850Gi` against each node's *allocatable ephemeral-storage*, which sits below the raw filesystem size — so a host with exactly 850 GB will not reliably pass. Applies **per node**, multi-node included (Longhorn also replicates volumes across nodes). |

> **Provisioning the floor:** a host provisioned at *exactly* the RAM floor reports slightly less than
> allocated (firmware/kernel reserve) — a "20 GB" node shows ~19 GiB, a "36 GB" node ~35 GiB. That is
> expected; `scripts/preflight.sh` accepts a ~2 GiB tolerance so a correctly-sized node passes. If you have
> the headroom, provisioning ~1 GB above the floor avoids any ambiguity.

> **DDPC add-on:** Dell Distributed Private Cloud adds ~10 single-replica services and a handful of one-shot
> jobs to the orchestrator namespace, no PVCs. Its own installer has **no resource gate**, so `ap-tools`
> checks *headroom* — allocatable minus what DAP's pods already request — and requires
> `DDPC_REQUIRED_CPU_HEADROOM=2` cores / `DDPC_REQUIRED_MEM_HEADROOM_GB=4` GB free, plus
> `DDPC_REQUIRED_DISK_GB=30` GB under `ap-install/` (6 GB zip + 6 GB extraction + a ~9 GB transient docker load + ~9 GB of images pulled into containerd; a validated install grew the node by 23 GB). A
> correctly-sized DAP host has this headroom; no extra provisioning is normally needed.

> **Multi-node disk:** prefer **≥1 TB/node**. At the 500–600 GB floor, DAP's large replica-3 Longhorn
> volumes (OpenSearch, vmstorage) can hit `ReplicaSchedulingFailure: insufficient storage` because the tool
> sets Longhorn over-provisioning to 200%. If you must run smaller disks, raise
> `storage-over-provisioning-percentage` (e.g. to 400 — volumes are thin-provisioned, so real usage stays
> low). See [troubleshooting.md](troubleshooting.md) #17.

## Multi-node also needs a free ingress VIP IP
Beyond the per-node IPs, a multi-node cluster needs **one extra free IP** in the nodes' L2 subnet (outside
any DHCP range, not a node IP) for the **MetalLB ingress VIP** (`LB_IP`). The `portal.`/`orchestrator.`/`mtls-*`
DNS records point at this VIP; the cluster/`-tls-san` name points at the node IPs. See
[dns-and-certs.md](dns-and-certs.md) for the DNS split and [topology.md](topology.md) for why the VIP is
ingress-only (not an API-server LB).

## Operating system
x86_64 Linux. Supported `/etc/os-release` IDs:
`ubuntu, debian, rhel, centos, rocky, almalinux, fedora, sles, opensuse-leap`.
Primary test matrix: Ubuntu 22.04+, RHEL 9.2+, SLES 15 SP7.

## Network & host
- A **static IP** (or DHCP reservation) per host.
- A **DNS-1123 hostname** (lowercase letters, digits, hyphens) — RKE2 uses it as the Kubernetes node
  name.
- Root / sudo access.
- **Accurate, consistent time (NTP).** All nodes must agree on the clock — skew breaks etcd quorum, TLS, and
  DAP tokens. Have a reachable NTP source ready and pass it as `NTP_SERVERS` so the tool configures it on every
  node (internal/air-gapped sources are common). If relying on the OS default, confirm the hosts are already
  synced (`timedatectl`).
- Outbound internet for an online install (or build an air-gap bundle on a connected host).

## Optional companion hosts
- **Harbor** (only if you don't already have a registry): ~4 vCPU / 8 GB / 500 GB. Can be a separate
  host.
- **SeaweedFS** (only if you want Velero backups): ~2–4 vCPU / 4–8 GB, storage sized to your artifacts.
- **DNS server** (only if you have no DNS for the required records — `install dns-server`): ~2 vCPU / 2–4 GB /
  20 GB, static IP, ports 53 (tcp/udp) + 5380 reachable. **Must be its own host, never an RKE2 node** (it takes
  over port 53 and the host resolver). See [dns-and-certs.md](dns-and-certs.md) "Option B".

Co-locating a registry or storage service on the RKE2 host is discouraged — port and resource
contention with the platform services. Co-locating the DNS server there is refused by the tool.
