# Automation Platform Tools

An unofficial prerequisite toolkit for deploying [Dell Automation Platform](https://www.dell.com/en-us/lp/dt/automation-platform) on-premise. The `ap-tools` script automates provisioning of a single- or multi-node RKE2 Kubernetes cluster together with the supporting infrastructure services (registry, storage, backups, monitoring) required by the Automation Platform bundle.

> **Disclaimer** &mdash; This repository is not associated with Dell Technologies and is not officially supported. The tooling is based on system requirements from official Dell Automation Platform documentation and leverages open-source components. While it follows common best practices, it may not be suitable for every enterprise environment. Consult the upstream vendor documentation (linked at the bottom) for production guidance.

## Architecture Overview

`ap-tools` orchestrates several helper scripts pulled at runtime from companion repositories:

| Helper | Repository | Purpose |
|:-------|:-----------|:--------|
| `install_packages.sh` | `install-packages` | OS package installation (online/offline/save) |
| `image_pull_push.sh` | `images-pull-push` | Container image pull, push, and registry cert handling |
| `rke2_installer.sh` | `rke2-installer` | RKE2 install, join, push, save, Velero, and monitoring |
| `install_harbor.sh` | `harbor-registry-installer` | Harbor OCI registry deployment |
| `install-seaweedfs` | `seaweedfs-installer` | SeaweedFS object/file storage deployment |

## Feature Summary

| Capability | Description |
|:-----------|:------------|
| **RKE2 Kubernetes** | Single- or multi-node RKE2 cluster with Calico CNI, Longhorn storage, MetalLB load balancer, and HAProxy ingress. |
| **Dell AP Bundle** | Downloads, extracts, and prepares the Automation Platform install bundle; outputs the final install command. |
| **Harbor Registry** | Deploys a Harbor OCI registry with self-signed TLS and pre-created project paths. |
| **SeaweedFS** | Deploys a single-node SeaweedFS instance providing S3, Filer, SMB, and NFS interfaces for artifact storage. |
| **Velero Backup** | Installs Velero with AWS/S3 plugin, Longhorn CSI snapshot support, and scheduled backups to SeaweedFS S3. |
| **Monitoring** | Deploys kube-prometheus-stack and Fluent Bit with remote-write to an external Prometheus/Loki host and ServiceMonitor auto-discovery. |
| **Air-Gapped / Offline** | Packages all binaries, images, and charts into `ap-offline.tar.gz` for fully disconnected installations. |
| **Registry Push** | Pulls all required container images and pushes them to a user-specified registry. |
| **Cluster Join** | Joins additional server or agent nodes to an existing RKE2 cluster. |

---

## CLI Reference

### Synopsis

```
ap-tools [COMMAND] [OPTIONS]
```

The script must be run as **root** (or via `sudo`). Air-gapped mode is auto-detected when `ap-offline.tar.gz` is present in the working directory.

### Commands

#### `install <component>`

Installs a component and its dependencies. When `ap-offline.tar.gz` is present, installation runs in air-gapped mode automatically.

| Component | Description | Required Options |
|:----------|:------------|:-----------------|
| `rke2` | Provisions an RKE2 server node with Helm, MetalLB, HAProxy ingress, Longhorn, and k9s. | None (optional: `-registry`, `-tls-san`, `push`) |
| `ap-bundle` | Extracts the Dell AP install bundle, runs preflight checks, configures the host, and outputs the `install-upgrade.sh` command. | `-registry` |
| `harbor` | Deploys a Harbor registry with auto-generated self-signed certificates and pre-created projects. | None |
| `swfs` | Deploys a single-node SeaweedFS server with S3, Filer, optional SMB/NFS, and Caddy reverse proxy. | None (optional: `-registry`, `push`) |
| `velero` | Installs Velero with CSI snapshot support, Longhorn integration, and SeaweedFS S3 backend. | Requires `VELERO_S3_URL`, `VELERO_S3_ACCESS_KEY`, `VELERO_S3_SECRET_KEY` set in script. Optional: `push`, `-registry`. |
| `monitoring` | Deploys kube-prometheus-stack and Fluent Bit; configures remote-write and ServiceMonitor auto-discovery. | Requires `MONITORING_HOST` set in script. |

#### `offline-prep`

Creates `ap-offline.tar.gz` containing all binaries, container images, Helm charts, and OS packages for a fully disconnected installation. Cannot be combined with `install`, `push`, or `join`. Requires an active internet connection.

#### `push`

Pulls all RKE2 and utility container images from upstream registries and pushes them to a specified local registry. Does **not** push Dell Automation Platform images (those are handled by `install-upgrade.sh`).

Requires: `-registry`

#### `join <server|agent> <server-fqdn> <join-token>`

Joins the current host to an existing RKE2 cluster.

| Role | Description |
|:-----|:------------|
| `server` | Joins as a control-plane node. Supports `-tls-san` and `-registry`. |
| `agent` | Joins as a worker-only node. Supports `-registry`. |

### Options

#### `-tls-san <fqdn-or-ip>`

Adds an additional Subject Alternative Name to the RKE2 API server certificate. Required for multi-node clusters where nodes connect through a shared cluster FQDN or VIP.

Valid with: `install rke2`, `join server`.

#### `-registry <host:port> <username> <password>`

Configures a private registry for container images. The value must be an FQDN or IPv4 address with a port (e.g., `registry.lab:8443`). Do not include `https://`.

Valid with: `install rke2`, `install ap-bundle`, `install swfs`, `push`, `join`.

#### `-h`, `--help`

Prints the usage summary and exits.

### Valid Command Combinations

The script validates argument combinations at startup. The following table shows supported permutations:

| Command | Example |
|:--------|:--------|
| `install rke2` | `./ap-tools install rke2` |
| `install rke2 -tls-san <fqdn>` | `./ap-tools install rke2 -tls-san cluster.lab` |
| `install rke2 -registry <r> <u> <p>` | `./ap-tools install rke2 -registry reg.lab:443 admin pass` |
| `install rke2 -registry <r> <u> <p> -tls-san <fqdn>` | `./ap-tools install rke2 -registry reg.lab:443 admin pass -tls-san cluster.lab` |
| `install rke2 push -registry <r> <u> <p>` | `./ap-tools install rke2 push -registry reg.lab:443 admin pass` |
| `install rke2 push -registry <r> <u> <p> -tls-san <fqdn>` | `./ap-tools install rke2 push -registry reg.lab:443 admin pass -tls-san cluster.lab` |
| `install ap-bundle -registry <r> <u> <p>` | `./ap-tools install ap-bundle -registry reg.lab:443 admin pass` |
| `install harbor` | `./ap-tools install harbor` |
| `install swfs` | `./ap-tools install swfs` |
| `install velero` | `./ap-tools install velero` |
| `install monitoring` | `./ap-tools install monitoring` |
| `push -registry <r> <u> <p>` | `./ap-tools push -registry reg.lab:443 admin pass` |
| `join server <fqdn> <token>` | `./ap-tools join server node1.lab K10...` |
| `join server <fqdn> <token> -tls-san <fqdn>` | `./ap-tools join server node1.lab K10... -tls-san cluster.lab` |
| `join server <fqdn> <token> -registry <r> <u> <p>` | `./ap-tools join server node1.lab K10... -registry reg.lab:443 admin pass` |
| `join server <fqdn> <token> -registry <r> <u> <p> -tls-san <fqdn>` | `./ap-tools join server node1.lab K10... -registry reg.lab:443 admin pass -tls-san cluster.lab` |
| `join agent <fqdn> <token>` | `./ap-tools join agent node1.lab K10...` |
| `join agent <fqdn> <token> -registry <r> <u> <p>` | `./ap-tools join agent node1.lab K10... -registry reg.lab:443 admin pass` |
| `offline-prep` | `./ap-tools offline-prep` |

---

## Configuration Variables

All user-configurable variables are defined at the top of the `ap-tools` script. Edit them before running, or override select variables via environment export (e.g., `sudo MGMT_IP=10.0.0.5 ./ap-tools install rke2`).

### Global

| Variable | Default | Description |
|:---------|:--------|:------------|
| `DEBUG` | `1` | Debug output. `1` = verbose, `0` = suppress helper output. |
| `MGMT_IP` | Auto-detected (`hostname -I`) | Primary management IP. Used as the RKE2 node-ip, MetalLB pool address, and service bind address. Override for multi-homed hosts. |
| `BASE_DOMAIN` | `edge.lab` | Base DNS domain appended to hostnames. |
| `HOST_FQDN` | `$(hostname).$BASE_DOMAIN` | Fully qualified hostname for AP, Harbor, and SeaweedFS service FQDNs. |
| `SWFS_HARBOR_USER` | `admin` | Shared username for Harbor and SeaweedFS basic auth. |
| `SWFS_HARBOR_PASS` | `changeme` | Shared password for Harbor and SeaweedFS basic auth. |

### Dell Automation Platform

| Variable | Default | Description |
|:---------|:--------|:------------|
| `AP_BUNDLE_URL` | Dell download URL (v1.2.0.0) | URL to the AP on-premise bundle `.zip`. Set to a local filename if the bundle was downloaded manually into `ap-install/`. |
| `DOWNLOAD_AP_BUNDLE` | `false` | When `true`, the bundle is downloaded during `offline-prep` or `install rke2`. |
| `SKIP_IMAGES_LOADER` | `false` | When `true`, skips pushing AP images to the registry during `install-upgrade.sh`. |
| `REGISTRY_PROJECT_NAME` | `dell-automation` | Project/namespace on the registry for AP container images. |
| `ORCHESTRATOR_NAMESPACE` | `dell-orchestrator` | Kubernetes namespace for the Orchestrator. |
| `PORTAL_NAMESPACE` | `dell-portal` | Kubernetes namespace for the Portal. |
| `PORTAL_COOKIE_DOMAIN` | `$BASE_DOMAIN` | Cookie domain for Portal. Use the base domain or an IP for IP-based installs. |
| `ORCHESTRATOR_FQDN` | `orchestrator.$HOST_FQDN` | FQDN (or IP) for the Orchestrator endpoint. |
| `PORTAL_FQDN` | `portal.$HOST_FQDN` | FQDN (or `IP:Port`) for the Portal endpoint. Port must be >30000 for IP-based installs. |
| `PORTAL_INGRESS_CLASS_NAME` | `haproxy` | Ingress class for Portal. Change if using a non-default ingress controller. |
| `ORG_NAME` | `changeme` | Organization name for AP initial setup. |
| `ORG_DESC` | `changeme` | Organization description. |
| `FIRST_NAME` | `changeme` | Admin user first name. |
| `LAST_NAME` | `changeme` | Admin user last name. |
| `USERNAME` | `administrator` | Admin username. |
| `EMAIL` | `changeme@example.com` | Admin user email. |

### RKE2 Kubernetes

| Variable | Default | Description |
|:---------|:--------|:------------|
| `RKE2_VERSION` | `v1.32.5+rke2r1` | RKE2 release to install. |
| `CLUSTER_TYPE` | `single-node` | Set to `multi-node` when planning to join additional nodes (adjusts Longhorn replica count). |
| `MAX_PODS` | `250` | Maximum pods per node. |
| `CNI_TYPE` | `calico` | CNI plugin (`calico` or `canal`). |
| `CLUSTER_CIDR` | `10.42.0.0/16` | Pod CIDR range. |
| `SERVICE_CIDR` | `10.43.0.0/16` | Service CIDR range. |
| `INSTALL_DNS_UTILITY` | `true` | Deploy the `dnsutils` pod in the default namespace for DNS troubleshooting. |
| `INSTALL_LOCAL_PATH_PROVISIONER` | `false` | When `true`, uses Local Path Provisioner instead of Longhorn. |
| `LOCAL_PATH_PROVISIONER_VERSION` | `v0.0.32` | Local Path Provisioner version (only relevant when enabled). |
| `LONGHORN_VERSION` | `1.9.2` | Longhorn Helm chart version. |
| `LONGHORN_UI_PORT` | `31000` | NodePort for the Longhorn UI. |
| `METALLB_VERSION` | `0.15.2` | MetalLB Helm chart version. |
| `INSTALL_METALLB` | `true` | Install MetalLB load balancer. |
| `KUBERNETES_INGRESS_VERSION` | `1.45.0` | HAProxy kubernetes-ingress Helm chart version. |
| `HAPROXY_APP_VERSION` | `3.1.12` | HAProxy application/image version. |
| `INSTALL_HAPROXY` | `true` | Install HAProxy ingress controller. Must be `false` for IP-based installs. |
| `HELM_VERSION` | `3.12.0` | Helm CLI version to download. |
| `RKE2_DATA` | `default` | Custom path for etcd, containerd, and RKE2 data. Set to a valid local path or leave as `default`. |
| `KUBELET_DATA` | `default` | Custom path for kubelet data. |
| `PVC_DATA` | `default` | Custom path for Longhorn PVC storage. |

### Harbor Registry

| Variable | Default | Description |
|:---------|:--------|:------------|
| `HARBOR_VERSION` | `2.14.1` | Harbor release version. |
| `HARBOR_PORT` | `8443` | HTTPS port for Harbor. |
| `COUNTRY` | `US` | Certificate subject: country code. |
| `STATE` | `MA` | Certificate subject: state. |
| `LOCATION` | `EDGE` | Certificate subject: locality. |
| `ORGANIZATION` | `LAB` | Certificate subject: organization. |
| `HARBOR_COMMON_NAME` | `registry.$HOST_FQDN` | Certificate CN / Harbor FQDN. |
| `DURATION_DAYS` | `3650` | Self-signed certificate validity (days). |
| `PROJECTS` | *(see script)* | Space-separated list of Harbor projects created at install time. |

### SeaweedFS

| Variable | Default | Description |
|:---------|:--------|:------------|
| `SWFS_IMAGE` | `chrislusf/seaweedfs:latest` | SeaweedFS container image. |
| `CADDY_IMAGE` | `caddy:latest` | Caddy reverse-proxy container image. |
| `SWFS_ADMIN_FQDN` | `admin.$HOST_FQDN` | FQDN for the SeaweedFS Admin UI / Caddy landing page. |
| `SWFS_MASTER_FQDN` | `master.$HOST_FQDN` | FQDN for the SeaweedFS Master API. |
| `SWFS_FILER_FQDN` | `filer.$HOST_FQDN` | FQDN for the SeaweedFS Filer API. |
| `SWFS_S3_FQDN` | `s3.$HOST_FQDN` | FQDN for the SeaweedFS S3 API. |
| `ENABLE_SMB` | `true` | Enable an SMB share with basic auth. |
| `ENABLE_NFS` | `true` | Enable an NFS export (NFSv3, no auth). |
| `SWFS_ADMIN_PORT` | `9443` | Caddy / Admin UI HTTPS port. |
| `SWFS_MASTER_PORT` | `9333` | SeaweedFS Master port. |
| `SWFS_FILER_PORT` | `8888` | SeaweedFS Filer port. |
| `SWFS_S3_PORT` | `8333` | SeaweedFS S3 port. |
| `S3_BUCKET` | `velero` | Default S3 bucket created at startup. |
| `DEFAULT_FILER_DIR_NAME` | `artifacts` | Default Filer directory name. |
| `ARTIFACTS_TO_DOWNLOAD` | *(URLs in script)* | Space-separated URLs of artifacts downloaded into the Filer directory. |
| `ENABLE_MONITORING` | `true` | Expose Prometheus metrics from the SeaweedFS instance. |
| `MON_CLUSTER_NAME` | `edge-lab` | Cluster label applied to SeaweedFS metrics. |

### Velero Backup

| Variable | Default | Description |
|:---------|:--------|:------------|
| `VELERO_VERSION` | `v1.17.1` | Velero release version. |
| `VELERO_AWS_PLUGIN_VERSION` | `v1.13.0` | Velero AWS S3 plugin version. |
| `VELERO_BUCKET` | `velero` | S3 bucket for backup storage. |
| `VELERO_S3_URL` | *(empty)* | **Required.** SeaweedFS S3 endpoint (e.g., `https://s3.example.com:8333`). |
| `VELERO_S3_ACCESS_KEY` | *(empty)* | **Required.** S3 access key for the Velero bucket. |
| `VELERO_S3_SECRET_KEY` | *(empty)* | **Required.** S3 secret key for the Velero bucket. |
| `VELERO_BACKUP_TTL` | `720h` | Backup retention period (30 days). |
| `VELERO_BACKUP_SCHEDULE` | `0 2 * * *` | Cron schedule for automated backups (daily at 02:00). |
| `VSC_NAME` | `longhorn-snapshot-vsc` | VolumeSnapshotClass name for Longhorn CSI snapshots. |
| `VSC_DRIVER` | `driver.longhorn.io` | CSI driver for the VolumeSnapshotClass. |
| `VELERO_BACKUP_NAMESPACES` | `dell-portal,dell-orchestrator,haproxy-controller,metallb-system` | Comma-separated namespaces included in scheduled backups. |

### Monitoring

| Variable | Default | Description |
|:---------|:--------|:------------|
| `MONITORING_HOST` | *(empty)* | **Required for `install monitoring`.** FQDN or IP of the external monitoring host running Prometheus and Loki. |
| `CLUSTER_NAME` | `edge-lab` | Label attached to all metrics and logs for multi-cluster identification. |
| `KUBE_PROMETHEUS_STACK_VERSION` | `69.8.0` | kube-prometheus-stack Helm chart version. |
| `FLUENT_BIT_CHART_VERSION` | `0.55.0` | Fluent Bit Helm chart version (fluent/fluent-bit, `0.x.x` scheme). |
| `FLUENT_BIT_VERSION` | `4.2.2` | Fluent Bit application/image version. |
| `PROMETHEUS_RETENTION` | `48h` | In-cluster Prometheus data retention (short; long-term storage is on the external host). |
| `PROMETHEUS_STORAGE_SIZE` | `50Gi` | PVC size for in-cluster Prometheus. |
| `PROMETHEUS_STORAGE_CLASS` | `longhorn` | StorageClass for Prometheus PVCs. |
| `MONITOR_CONFIGS_DIR` | *(empty)* | Optional path to a directory of custom ServiceMonitor YAML files. |
| `MONITORING_LOKI_PORT` | `3100` | Loki HTTP port on the monitoring host. |
| `MONITORING_PROMETHEUS_PORT` | `9090` | Prometheus remote-write receiver port on the monitoring host. |
| `MONITOR_EXCLUDE_NS` | `kube-system kube-public kube-node-lease default monitoring` | Space-separated namespaces excluded from ServiceMonitor auto-discovery. |
| `MONITOR_PORT_NAMES` | `manager metrics http-metrics prometheus prom stat metrics-port` | Port names matched during ServiceMonitor auto-discovery. |

---

## Quick Start

```bash
# 1. Clone and make executable
git clone https://github.com/Chubtoad5/automation-platform-tools.git
cd automation-platform-tools
chmod +x ap-tools

# 2. (Optional) Edit user-defined variables
nano ap-tools

# 3. Run as root
sudo ./ap-tools install rke2
```

### One-liner

```bash
git clone https://github.com/Chubtoad5/automation-platform-tools.git && cd automation-platform-tools && chmod +x ap-tools && sudo ./ap-tools install rke2
```

---

## Usage Examples

### RKE2 Kubernetes

```bash
# Default single-node install
sudo ./ap-tools install rke2

# With TLS-SAN for multi-node cluster
sudo ./ap-tools install rke2 -tls-san rke2-cluster.mydomain.lab

# With a private registry
sudo ./ap-tools install rke2 -registry myregistry.lab:443 admin password

# Push images to registry, install RKE2, and add TLS-SAN
sudo ./ap-tools install rke2 push -registry myregistry.lab:443 admin password -tls-san rke2-cluster.mydomain.lab
```

### Cluster Join

```bash
# Join as a server node
sudo ./ap-tools join server myk8snode.mydomain.lab <token_string>

# Join as a server with registry and TLS-SAN
sudo ./ap-tools join server rke2-cluster.mydomain.lab <token_string> \
  -registry registry.mydomain.lab:443 admin password \
  -tls-san rke2-cluster.mydomain.lab

# Join as an agent node
sudo ./ap-tools join agent myk8snode.mydomain.lab <token_string>
```

### Push Images

```bash
# Push RKE2 and service images to a registry (no install)
sudo ./ap-tools push -registry myregistry.lab:8443 admin password
```

### Harbor Registry

```bash
sudo ./ap-tools install harbor
```

### SeaweedFS

```bash
sudo ./ap-tools install swfs
```

### Velero Backup

Before running, set `VELERO_S3_URL`, `VELERO_S3_ACCESS_KEY`, and `VELERO_S3_SECRET_KEY` in the script.

```bash
sudo ./ap-tools install velero
```

### Monitoring Stack

Before running, set `MONITORING_HOST` in the script to the FQDN or IP of the external Prometheus/Loki host.

```bash
sudo ./ap-tools install monitoring
```

### Dell Automation Platform Bundle

```bash
sudo ./ap-tools install ap-bundle -registry myregistry.lab:443 admin password
```

### Air-Gapped Workflow

```bash
# On a connected host: create the offline archive
sudo ./ap-tools offline-prep

# Copy ap-offline.tar.gz and ap-tools to the air-gapped host, then:
tar xzf ap-offline.tar.gz
sudo ./ap-tools install rke2
```

### Multi-Homed Hosts

Override the default management IP via environment variable:

```bash
sudo MGMT_IP=192.168.1.100 ./ap-tools install rke2
```

---

## Host Prerequisites

### Supported Operating Systems

x86_64 Linux only. The script validates `/etc/os-release` against: `ubuntu`, `debian`, `rhel`, `centos`, `rocky`, `almalinux`, `fedora`, `sles`, `opensuse-leap`.

Primary test matrix:

- Ubuntu Server 22.04 LTS or later
- Red Hat Enterprise Linux (RHEL) 9.2 or later
- SUSE Linux Enterprise Server (SLES) 15 SP7

### Minimum Resources

#### Automation Platform (RKE2 host)

| Resource | Minimum | Recommended |
|:---------|:--------|:------------|
| CPU | 16 vCPU | 16+ vCPU |
| Memory | 32 GB | 34 GB (RKE2 + services consume ~2 GB) |
| Storage | 500 GB SSD | 1 TB SSD |

Resource checks are performed against Kubernetes allocatable capacity (`kubectl get nodes`) during `install ap-bundle`.

#### SeaweedFS host

| Resource | Recommendation |
|:---------|:---------------|
| CPU | 2-4 vCPU |
| Memory | 4-8 GB |
| Storage | Sized to artifact requirements (blueprints, VM images, etc.) |

#### Harbor host

| Resource | Recommendation |
|:---------|:---------------|
| CPU | 4 vCPU |
| Memory | 8 GB |
| Storage | 500 GB SSD or larger |

---

## Network Requirements

### IP Assignment

- **RKE2 / Automation Platform**: Static IP or DHCP reservation is **required**. MetalLB binds the host's primary management IP at install time.
- **SeaweedFS / Harbor**: Static IP or DHCP reservation is strongly recommended.

### Hostname Considerations

RKE2 uses the system hostname as the Kubernetes node name. Node names must conform to DNS-1123 subdomain format (RFC 1123): lowercase alphanumeric with hyphens, matching `[a-z0-9]([-a-z0-9]*[a-z0-9])?`. Verify your hostname before installation.

### DNS Records

DNS A records are required for Automation Platform and strongly recommended for all other services. Example schema:

| Service | FQDN | IP Address |
|:--------|:------|:-----------|
| Harbor | `registry.harborhost.mydomain.lab` | 192.168.50.20 |
| SeaweedFS | `artifacts.swfshost.mydomain.lab` | 192.168.50.25 |
| RKE2 Node | `myk8snode.mydomain.lab` | 192.168.50.30 |
| RKE2 TLS-SAN (multi-node) | `myk8scluster.mydomain.lab` | 192.168.50.30, .31, .32 |
| AP Portal | `portal.myhost.mydomain.lab` | 192.168.50.30 |
| AP Orchestrator | `orchestrator.myhost.mydomain.lab` | 192.168.50.30 |
| AP mTLS | `mtls-orchestrator.myhost.mydomain.lab` | 192.168.50.30 |
| AP mTLS Recovery | `mtls-recovery-orchestrator.myhost.mydomain.lab` | 192.168.50.30 |
| Global Rendezvous (FDO) | `rv.dell.fdo` | 192.168.50.30 |

**Important DNS notes:**

- The TLS-SAN cluster entry is only needed for multi-node clusters; each server node should resolve to the shared FQDN.
- The `mtls-` and `mtls-recovery-` prefixes are hard requirements for Orchestrator device mTLS authentication.
- The `rv.dell.fdo` record is only required when Global Rendezvous is unavailable (e.g., air-gapped FDO onboarding).
- Avoid DNS zones named `.local` (conflicts with RFC 6762 mDNS) or `local.edge` (per Dell guidance).
- Wildcard DNS is supported. For example, `*.myhost.mydomain.lab` resolving to the AP host IP covers all four AP records with a single entry.

### Local Registry

When using a private registry, all required container images must exist on the registry or it must act as a pull-through mirror. The `push` command uses Docker Engine to pull and push images; Docker is installed automatically if not present.

`install harbor` automatically creates all required projects. When using a different registry, pre-create the following projects:

| Project | Source | Used By |
|:--------|:-------|:--------|
| `rancher` | docker.io | RKE2 core |
| `haproxytech` | docker.io | HAProxy ingress |
| `longhornio` | docker.io | Longhorn storage |
| `metallb` | quay.io | MetalLB load balancer |
| `frrouting` | quay.io | MetalLB (FRR backend) |
| `chrislusf` | docker.io | SeaweedFS |
| `e2e-test-images` | registry.k8s.io | DNS utility (when `INSTALL_DNS_UTILITY=true`) |
| `library` | docker.io | Local Path Provisioner (when `INSTALL_LOCAL_PATH_PROVISIONER=true`) |
| `velero` | docker.io | Velero backup |
| `grafana` | docker.io | Grafana (monitoring stack) |
| `prom` | docker.io | Prometheus components |
| `prometheus` | quay.io | Prometheus Operator |
| `prometheus-operator` | quay.io | Prometheus Operator |
| `kube-state-metrics` | registry.k8s.io | kube-state-metrics |
| `ingress-nginx` | registry.k8s.io | Ingress NGINX (monitoring) |
| `bats` | docker.io | Helm test images |
| `kiwigrid` | quay.io | Sidecar containers |
| `fluent` | docker.io | Fluent Bit |
| `$REGISTRY_PROJECT_NAME` | AP bundle | Dell Automation Platform images |

---

## Operational Notes

### Multi-Node Clusters

- Set `CLUSTER_TYPE=multi-node` before the initial `install rke2` to configure Longhorn with appropriate replica counts.
- Use `join` only against RKE2 clusters of the same version. Joining a cluster not created by this script may cause configuration conflicts.
- If the initial install used `-registry`, all joined nodes must also specify `-registry`.
- If the initial install used `-tls-san`, all joined server nodes must also specify `-tls-san`.

### Co-location Constraints

- Harbor and SeaweedFS may coexist on the same host provided they use different TCP ports.
- Running `install rke2` on the same host as Harbor or SeaweedFS is **not recommended** due to potential port and resource conflicts with Automation Platform services.

### Debug Mode

Set `DEBUG=1` (default) for verbose output from all helper scripts. Set `DEBUG=0` to suppress helper output and show only top-level progress messages.

### Additional Tools

| Tool | Description |
|:-----|:------------|
| **k9s** | Terminal UI for Kubernetes cluster management. Installed automatically during `install rke2`. Run with `k9s`. |
| **dnsutils** | Kubernetes DNS debugging pod (deployed to the `default` namespace). Disable with `INSTALL_DNS_UTILITY=false`. Usage: `kubectl exec -it dnsutils -- nslookup kubernetes.default` |
| **longhornctl** | Longhorn CLI for storage operations. Installed alongside Longhorn. |
| **logs.sh** | Dell support log collector (KB 000216838). Downloaded during `install ap-bundle` into `ap-install/ap-utilities/`. |

---

## Open-Source References

- [Rancher RKE2](https://docs.rke2.io/)
- [Kubernetes DNS Utility](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)
- [MetalLB](https://metallb.io/)
- [Longhorn](https://longhorn.io/)
- [HAProxy Tech Kubernetes Ingress](https://www.haproxy.com/documentation/kubernetes-ingress/)
- [Harbor](https://goharbor.io/)
- [SeaweedFS](https://github.com/seaweedfs/seaweedfs)
- [Velero](https://velero.io/)
- [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Fluent Bit](https://fluentbit.io/)
- [Caddy](https://caddyserver.com/)
- [K9s](https://k9scli.io/)

## Dell Technologies References

- [Dell Automation Platform](https://www.dell.com/en-us/lp/dt/automation-platform)
- [KB 000216838 - Log Collection](https://www.dell.com/support/kbdoc/en-us/000216838/how-to-retrieve-logs-bundle-for-troubleshooting-nativeedge-solution)

## Author Notes

Thanks to all the nerds out there who think infrastructure automation is fun and motivated me to make this tool!
