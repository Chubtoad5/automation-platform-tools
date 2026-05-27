# Prerequisites (what you provide)

This skill does **not** create infrastructure. You provision the host(s) yourself on whatever platform
you use — vSphere, Proxmox, KVM/libvirt, a public cloud, or bare metal. The requirements are the same
everywhere.

## Per-host sizing (Automation Platform / RKE2 host)

| Resource | Minimum | Notes |
|:--|:--|:--|
| CPU | 16 vCPU | |
| RAM | **34 GB** | Use 34, not 32. RKE2 + platform services reserve ~2 GB, and the DAP bundle's pre-flight measures *Kubernetes-allocatable* capacity — a 32 GB host fails it. |
| Disk | 500 GB SSD | 1 TB recommended, especially for multi-node (Longhorn replicates volumes across nodes). |

## Operating system
x86_64 Linux. Supported `/etc/os-release` IDs:
`ubuntu, debian, rhel, centos, rocky, almalinux, fedora, sles, opensuse-leap`.
Primary test matrix: Ubuntu 22.04+, RHEL 9.2+, SLES 15 SP7.

## Network & host
- A **static IP** (or DHCP reservation) per host.
- A **DNS-1123 hostname** (lowercase letters, digits, hyphens) — RKE2 uses it as the Kubernetes node
  name.
- Root / sudo access.
- Outbound internet for an online install (or build an air-gap bundle on a connected host).

## Optional companion hosts
- **Harbor** (only if you don't already have a registry): ~4 vCPU / 8 GB / 500 GB. Can be a separate
  host.
- **SeaweedFS** (only if you want Velero backups): ~2–4 vCPU / 4–8 GB, storage sized to your artifacts.

Co-locating a registry or storage service on the RKE2 host is discouraged — port and resource
contention with the platform services.
