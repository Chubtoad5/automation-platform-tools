# Manual Install: Dell Automation Platform + DDPC on Ubuntu 24.04 (connected, single-node)

A step-by-step guide for installing **RKE2 Kubernetes**, **Dell Automation Platform (DAP) 2.1.1.0** and the
**Dell Distributed Private Cloud (DDPC) 4.3.0.0** add-on **by hand** on one internet-connected Ubuntu 24.04 host.

This guide does by hand what `ap-tools install rke2`, `ap-tools install ap-bundle` and
`ap-tools install ddpc-bundle` do automatically (single-node). Use it when you want to understand every step,
can't run the script in your environment, or need to troubleshoot an automated install. If you just want a
working system, the [Quick Start in the main README](../../README.md#quick-start-single-node) is faster.

> **Disclaimer** &mdash; This guide is not associated with Dell Technologies and is not officially supported.
> Always consult the official Dell Automation Platform documentation for production guidance.

---

## Table of Contents

- [What you will build](#what-you-will-build)
- [Conventions used in this guide](#conventions-used-in-this-guide)
- [Requirements checklist](#requirements-checklist)
- [Step 0 — Record your values](#step-0--record-your-values)
- [Step 1 — Prepare the host](#step-1--prepare-the-host)
- [Step 2 — Install RKE2](#step-2--install-rke2)
- [Step 3 — Install Helm and the platform charts](#step-3--install-helm-and-the-platform-charts)
- [Step 4 — Trust the registry and install Docker](#step-4--trust-the-registry-and-install-docker)
- [Step 5 — Install Dell Automation Platform](#step-5--install-dell-automation-platform)
- [Step 6 — Install Dell Distributed Private Cloud](#step-6--install-dell-distributed-private-cloud)
- [Step 7 — Final verification](#step-7--final-verification)
- [Troubleshooting](#troubleshooting)
- [Appendix A — Uninstall and clean-up](#appendix-a--uninstall-and-clean-up)
- [Appendix B — How these steps map to ap-tools](#appendix-b--how-these-steps-map-to-ap-tools)

---

## What you will build

One Ubuntu 24.04 host running:

| Layer | Component | Version | Purpose |
|:--|:--|:--|:--|
| Kubernetes | RKE2 (Calico CNI) | `v1.34.5+rke2r1` | Single-node cluster; the built-in NGINX ingress is **disabled** |
| Load balancer | MetalLB (L2) | chart `0.15.3` | Gives the ingress a `LoadBalancer` IP (the host IP) |
| Ingress | HAProxy Kubernetes Ingress | chart `1.49.0`, app `3.2.6` | Ingress class `haproxy`, with **SSL passthrough** (required for DAP mTLS) |
| Storage | Longhorn | `1.11.1` | Default `StorageClass` for DAP's persistent volumes |
| Tooling | Helm | `4.0.1` | Installs the charts above; Dell's installers also need it |
| Tooling | Docker CE | latest stable | Dell's image loaders use Docker to push images to your registry |
| Application | Dell Automation Platform | `2.1.1.0` | Portal + Orchestrator |
| Add-on | Dell Distributed Private Cloud | `4.3.0.0` | Installed into the running orchestrator |

When you finish, the portal answers at `https://portal.<HOST_FQDN>` and the orchestrator at
`https://orchestrator.<HOST_FQDN>`.

**Time needed:** about 2–3 hours, most of it waiting for downloads and image pushes.

---

## Conventions used in this guide

- **Run every command as root.** Start a root shell once with `sudo -i` and stay in it.
- Values in `<ANGLE_BRACKETS>` are placeholders. You set them once in [Step 0](#step-0--record-your-values)
  and then the commands use them as shell variables (`$HOST_FQDN`, `$REGISTRY` …), so you can paste the
  commands as they are.
- Every step ends with a **Verify** block. Don't move on until it shows the expected result.
- Long-running commands (the DAP and DDPC installs) should run inside `screen` or `tmux`, so an SSH
  disconnect does not kill them.

---

## Requirements checklist

Work through this list **before** you start. Each item has a command to check it.

### Host

- [ ] **Fresh Ubuntu 24.04 LTS, x86_64**, with nothing else installed on it (no other Kubernetes, no Docker
  workloads, nothing listening on ports 80/443).
  Check: `lsb_release -ds; uname -m`
- [ ] **CPU: 18 vCPU or more** (20 recommended once DDPC is added).
  Check: `nproc`
- [ ] **RAM: 36 GB or more.** DAP's pre-check measures the *allocatable* memory Kubernetes reports, which is
  about 2 GB below what you provision; 34 GB allocatable is the practical floor, so provision 36 GB. DDPC needs
  about 4 GB more of free headroom; 40 GB gives comfortable room.
  Check: `free -g`
- [ ] **Disk: 1 TB or more on the root filesystem (SSD).** DAP 2.1.1.0 refuses to install unless the node
  reports **850 GiB of allocatable ephemeral-storage**, and allocatable is always a bit below the raw size.
  Check: `df -h /`
- [ ] **Static IP** (or a DHCP reservation) on the management interface.
  Check: `ip -br -4 addr`
- [ ] **Hostname** in lowercase letters, numbers and hyphens only, and `hostname -f` returns the full name.
  Check: `hostname; hostname -f`
- [ ] **Time is synchronised** (NTP). Clock drift breaks certificates and pod networking.
  Check: `timedatectl show -p NTPSynchronized` → `NTPSynchronized=yes`
- [ ] **Outbound HTTPS** to `get.rke2.io`, `github.com`, `objects.githubusercontent.com`, `get.helm.sh`,
  `metallb.github.io`, `haproxytech.github.io`, `charts.longhorn.io`, `download.docker.com`, `dl.dell.com`,
  the container registries RKE2/MetalLB/HAProxy/Longhorn pull from (`docker.io`, `quay.io`), and your own
  registry.
  Check: `curl -sI https://get.rke2.io | head -1`

### DNS

Create these records on your DNS server **before** you start. All of them point at the host IP. The two
`mtls-` names are **hard requirements** — device onboarding fails without them.

| Record | Type | Value |
|:--|:--|:--|
| `<HOST_FQDN>` (e.g. `dap1.example.lab`) | A (+ PTR) | `<HOST_IP>` |
| `portal.<HOST_FQDN>` | A | `<HOST_IP>` |
| `orchestrator.<HOST_FQDN>` | A | `<HOST_IP>` |
| `mtls-orchestrator.<HOST_FQDN>` | A | `<HOST_IP>` |
| `mtls-recovery-orchestrator.<HOST_FQDN>` | A | `<HOST_IP>` |

> **Tip:** one wildcard record `*.<HOST_FQDN>` → `<HOST_IP>` covers the four service names.

> **Avoid** `.local` domains, and avoid TLDs on the browser HSTS preload list (such as `.dev` and `.app`):
> DAP uses self-signed certificates, and browsers refuse self-signed certificates on those TLDs.

- [ ] Every name resolves **from the host itself**.
  Check: `for n in portal orchestrator mtls-orchestrator mtls-recovery-orchestrator; do getent hosts $n.<HOST_FQDN>; done`

### Container registry

DAP and DDPC do not pull from Dell's servers. Their installers **push** the images from the bundles into
**your** OCI registry (Harbor or any compatible registry), and Kubernetes pulls them from there.

- [ ] An OCI registry reachable over **HTTPS** from the host, as `<host>:<port>` (e.g. `registry.example.lab:443`).
- [ ] A **project / namespace** in it for Dell's images, created beforehand (this guide calls it
  `dell-automation`, the ap-tools default). DAP and DDPC both use it. Note its **exact** name: the installers
  do not create it, and a typo only shows up as a failed push about 5 minutes into the DAP install.
- [ ] A **username and password** with push and pull rights on that project.
- [ ] Room for the images: about **25 GB** of storage in the registry for DAP + DDPC.
- [ ] The host can reach the registry.
  Check: `curl -s -o /dev/null -w '%{http_code}\n' https://<host>:<port>/v2/` → `401` (or `200`) means reachable.

> Don't have a registry? A Harbor install guide is planned for this `docs/` folder. Until then,
> `ap-tools install harbor` installs one for you (see the main README).

### Dell bundles

- [ ] **DAP 2.1.1.0** bundle: `Dell_Automation_Platform_Linux_2.1.1.0.zip` (about 16.4 GB), from
  `https://dl.dell.com/FOLDER14962193M/1/Dell_Automation_Platform_Linux_2.1.1.0.zip`
- [ ] **DDPC 4.3.0.0** bundle: `dell-distributed-private-cloud_4.3.0.0.zip` (about 6.2 GB), from
  `https://dl.dell.com/FOLDER14941030M/1/dell-distributed-private-cloud_4.3.0.0.zip`
- [ ] About **60 GB free** on the host for downloading and extracting both bundles (the extracted trees can be
  deleted after the install).

You can download them on the host in [Step 5](#step-5--install-dell-automation-platform) and
[Step 6](#step-6--install-dell-distributed-private-cloud), or copy them there with `scp` if you already
have them. The links change with every release — use the ones from Dell's support site for other versions.

### Administrator identity

- [ ] **Organization name** and **description** (e.g. `Example Corp`, `Example Corp lab DAP`).
- [ ] The first **administrator**: first name, last name, **username** and **email**. The initial password is
  set by Dell's installer to `Temporary@123`, and you must change it at first login.

---

## Step 0 — Record your values

Open a root shell and write your values into a small file. Every later step reads it, so if your SSH session
drops you only have to `source` it again.

```bash
sudo -i

cat > /root/dap-install.env <<'EOF'
# --- Host ---
export HOST_FQDN="dap1.example.lab"        # the host's full DNS name (the DNS records hang off this)
export HOST_IP="192.0.2.10"                # the host's static IP
export BASE_DOMAIN="example.lab"           # the domain the portal cookie is scoped to (usually HOST_FQDN minus the host label)

# --- Registry ---
export REGISTRY="registry.example.lab:443" # <host>:<port>, no https://
export REG_PROJECT="dell-automation"       # the project you created for Dell's images - must match its name exactly
export REG_USER="admin"
export REG_PASS='change-me'                # keep the single quotes if the password has special characters

# --- DAP administrator ---
export ORG_NAME="Example Corp"
export ORG_DESC="Example Corp lab DAP"
export FIRST_NAME="Example"
export LAST_NAME="Admin"
export ADMIN_USERNAME="administrator"
export ADMIN_EMAIL="admin@example.lab"

# --- Versions (the ones this guide was tested with) ---
export RKE2_VERSION="v1.34.5+rke2r1"
export HELM_VERSION="4.0.1"
export METALLB_VERSION="0.15.3"
export HAPROXY_CHART_VERSION="1.49.0"
export HAPROXY_APP_VERSION="3.2.6"
export LONGHORN_VERSION="1.11.1"

# --- Working directory for downloads and bundles ---
export WORK_DIR="/opt/dap-install"
EOF
chmod 600 /root/dap-install.env
source /root/dap-install.env
mkdir -p "$WORK_DIR"
```

Find the name of the network interface that carries `HOST_IP` (MetalLB needs it) and add it to the file:

```bash
MGMT_IF=$(ip -o -4 addr show | awk -v ip="$HOST_IP" '$4 ~ "^"ip"/" {print $2; exit}')
echo "export MGMT_IF=\"$MGMT_IF\"" >> /root/dap-install.env
source /root/dap-install.env
echo "Management interface: $MGMT_IF"
```

**Verify:** `echo $MGMT_IF` prints an interface name (such as `eth0` or `ens18`). If it is empty, `HOST_IP`
does not match any address on the host — fix the file and try again.

> **New shell later?** Run `sudo -i` and then `source /root/dap-install.env` before continuing.

---

## Step 1 — Prepare the host

### 1.1 Wait for cloud-init (cloud images only)

On a freshly cloned cloud image, cloud-init may still be running package updates and holding the apt lock.

```bash
cloud-init status --wait 2>/dev/null || true
```

### 1.2 Install the prerequisite packages

```bash
apt-get update
apt-get install -y curl jq zip unzip bc openssl screen nfs-common open-iscsi cryptsetup
```

`nfs-common`, `open-iscsi` and `cryptsetup` are what Longhorn needs on every node; the rest are used by this
guide and by Dell's installers.

### 1.3 Load the kernel modules

```bash
cat > /etc/modules-load.d/40-k8s.conf <<'EOF'
overlay
br_netfilter
dm_crypt
nfs
EOF
modprobe -a overlay br_netfilter dm_crypt nfs
```

### 1.4 Turn swap off

```bash
swapoff -a
sed -i -e '/\sswap\s/d' /etc/fstab
```

### 1.5 Kernel settings

Kubernetes networking settings, plus the higher **inotify** limits DAP needs (without them DAP's log
collector, fluent-bit, crashes with "too many open files"):

```bash
cat > /etc/sysctl.d/40-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

cat > /etc/sysctl.d/10-ap-orchestrator.conf <<'EOF'
fs.inotify.max_user_watches = 1048576
fs.inotify.max_user_instances = 1024
EOF

systemctl restart systemd-sysctl
```

### 1.6 Disable multipathd

Ubuntu runs `multipathd` by default. It grabs the iSCSI disks Longhorn attaches and breaks every volume mount
(`exit status 32` / `Can't open blockdev`). Blacklist `sd*` devices, then stop, disable and mask the service:

```bash
mkdir -p /etc/multipath/conf.d
cat > /etc/multipath/conf.d/99-dap.conf <<'EOF'
# Keep multipathd away from Longhorn iSCSI devices
blacklist {
    devnode "^sd[a-z0-9]+"
}
EOF
systemctl stop multipathd.service multipathd.socket 2>/dev/null || true
systemctl disable multipathd.service multipathd.socket 2>/dev/null || true
systemctl mask multipathd.service multipathd.socket 2>/dev/null || true
```

### 1.7 Enable iscsid

Longhorn attaches volumes over iSCSI, so `iscsid` must start at boot:

```bash
if systemctl list-unit-files --no-legend | grep -q '^iscsid\.socket'; then
  systemctl enable --now iscsid.socket
else
  systemctl enable --now iscsid.service
fi
```

### 1.8 Turn the host firewall off

RKE2 and Calico manage their own packet-filter rules.

```bash
ufw disable
```

### Verify

```bash
lsmod | grep -E '^(overlay|br_netfilter|dm_crypt|nfs) ' | awk '{print $1}'   # 4 modules
swapon --show | wc -l                                                          # 0
sysctl fs.inotify.max_user_instances net.ipv4.ip_forward                       # 1024 and 1
systemctl is-enabled multipathd.service multipathd.socket                      # masked, masked
systemctl is-enabled iscsid.socket 2>/dev/null || systemctl is-enabled iscsid.service   # enabled
ufw status                                                                     # Status: inactive
timedatectl show -p NTPSynchronized                                            # NTPSynchronized=yes
```

---

## Step 2 — Install RKE2

### 2.1 Write the RKE2 configuration

Ubuntu points `/etc/resolv.conf` at the local systemd-resolved stub (`127.0.0.53`). Kubernetes must **not**
be handed that file, or CoreDNS detects a forwarding loop and crash-loops. The configuration below points the
kubelet at `/run/systemd/resolve/resolv.conf`, which lists your real DNS servers.

```bash
mkdir -p /etc/rancher/rke2
cat > /etc/rancher/rke2/config.yaml <<EOF
cni: "calico"
write-kubeconfig-mode: "0600"
service-node-port-range: "443-40000"
cluster-cidr: "10.42.0.0/16"
service-cidr: "10.43.0.0/16"
advertise-address: "$HOST_IP"
node-ip: "$HOST_IP"
etcd-extra-env:
  - "ETCD_AUTO_COMPACTION_RETENTION=72h"
  - "ETCD_AUTO_COMPACTION_MODE=periodic"
kube-apiserver-arg:
  - "audit-log-path=/var/lib/rancher/rke2/server/logs/rke2-apiserver-audit.log"
  - "audit-log-maxage=30"
  - "audit-log-maxbackup=10"
  - "audit-log-maxsize=200"
kubelet-arg:
  - "max-pods=250"
  - "resolv-conf=/run/systemd/resolve/resolv.conf"
disable:
  - rke2-ingress-nginx
tls-san:
  - "$HOST_FQDN"
EOF
cat /etc/rancher/rke2/config.yaml
```

What the settings do:

| Setting | Why |
|:--|:--|
| `cni: calico` | The CNI DAP is validated with |
| `disable: rke2-ingress-nginx` | DAP uses the HAProxy ingress installed in Step 3; two ingress controllers would fight over ports 80/443 |
| `service-node-port-range: 443-40000` | Widens the NodePort range so low ports can be used |
| `max-pods: 250` | DAP runs well over the default limit of 110 pods on one node |
| `resolv-conf` | Avoids the CoreDNS loop described above |
| `tls-san` | Adds the host FQDN to the API server certificate, so `kubectl` works against the name too |
| `etcd-extra-env`, `audit-log-*` | etcd history compaction and a rotated API audit log |

> **Check your DNS servers:** `grep nameserver /run/systemd/resolve/resolv.conf` should list your real DNS
> server(s), not `127.0.0.53`. If the file is missing or empty, fix systemd-resolved before continuing.

### 2.2 Configure CoreDNS

This makes CoreDNS forward cluster-external names to the host's DNS servers. RKE2 applies files placed in
its `manifests` directory automatically when it starts.

```bash
mkdir -p /var/lib/rancher/rke2/server/manifests
cat > /var/lib/rancher/rke2/server/manifests/rke2-coredns-helmchartconfig.yaml <<'EOF'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-coredns
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      name: kube-dns
    servers:
    - zones:
      - zone: .
      port: 53
      plugins:
      - name: errors
      - name: health
        configBlock: |-
          lameduck 5s
      - name: ready
      - name: kubernetes
        parameters: cluster.local in-addr.arpa ip6.arpa
        configBlock: |-
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
          ttl 30
      - name: prometheus
        parameters: 0.0.0.0:9153
      - name: forward
        parameters: . /etc/resolv.conf
      - name: cache
        parameters: 30
      - name: loop
      - name: reload
      - name: loadbalance
EOF
```

### 2.3 Install and start RKE2

```bash
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="$RKE2_VERSION" sh -
systemctl enable --now rke2-server.service
```

The first start takes several minutes while RKE2 pulls its images. Follow it with
`journalctl -u rke2-server -f` (press Ctrl+C to stop following) if you want to watch.

> **Over SSH:** `systemctl enable --now rke2-server` can take long enough that a flaky SSH session drops. If
> that happens, reconnect — the service keeps starting in the background. Check with
> `systemctl status rke2-server`.

### 2.4 Set up kubectl

```bash
mkdir -p /root/.kube
cp /etc/rancher/rke2/rke2.yaml /root/.kube/config
chmod 600 /root/.kube/config

ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
ln -sf /var/lib/rancher/rke2/bin/crictl  /usr/local/bin/crictl
ln -sf /var/lib/rancher/rke2/bin/ctr     /usr/local/bin/ctr
cat > /etc/profile.d/rke2.sh <<'EOF'
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
EOF
```

Optional — give your normal login user `kubectl` access too (replace `<YOUR_USER>`):

```bash
mkdir -p /home/<YOUR_USER>/.kube
cp /etc/rancher/rke2/rke2.yaml /home/<YOUR_USER>/.kube/config
chown -R <YOUR_USER>:<YOUR_USER> /home/<YOUR_USER>/.kube
chmod 600 /home/<YOUR_USER>/.kube/config
```

### Verify

```bash
kubectl get nodes -o wide     # one node, STATUS Ready, VERSION v1.34.5+rke2r1, INTERNAL-IP = HOST_IP
kubectl get pods -A           # everything Running or Completed after a few minutes
kubectl get pods -n kube-system | grep -c ingress-nginx   # 0 - the built-in ingress is disabled
kubectl -n kube-system get pods -l k8s-app=kube-dns       # CoreDNS Running, not CrashLoopBackOff
```

Wait until **every** pod is `Running` or `Completed` before moving on. You can watch with
`kubectl get pods -A -w` (Ctrl+C to stop).

---

## Step 3 — Install Helm and the platform charts

### 3.1 Install Helm

```bash
curl -fsSLo "$WORK_DIR/helm.tar.gz" "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
tar -xzf "$WORK_DIR/helm.tar.gz" -C "$WORK_DIR"
install -m 0755 "$WORK_DIR/linux-amd64/helm" /usr/local/bin/helm
rm -rf "$WORK_DIR/linux-amd64" "$WORK_DIR/helm.tar.gz"

helm repo add metallb https://metallb.github.io/metallb
helm repo add haproxytech https://haproxytech.github.io/helm-charts
helm repo add longhorn https://charts.longhorn.io
helm repo update
```

**Verify:** `helm version` reports `v4.0.1`.

### 3.2 MetalLB (load balancer)

MetalLB gives the ingress controller's `LoadBalancer` service an IP address. On a single node that address is
the host's own IP.

```bash
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system --create-namespace --version "$METALLB_VERSION"

kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=300s
kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=300s
```

Once the MetalLB pods are ready, create the address pool and announce it on the management interface:

```bash
mkdir -p "$WORK_DIR/helm"
cat > "$WORK_DIR/helm/metallb-config.yaml" <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-ip-pool
  namespace: metallb-system
spec:
  addresses:
    - $HOST_IP/32
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-ip-pool
  interfaces:
    - $MGMT_IF
EOF
kubectl apply -f "$WORK_DIR/helm/metallb-config.yaml"
```

> If `kubectl apply` fails with a webhook error ("failed calling webhook … connection refused"), MetalLB's
> webhook is not ready yet. Wait 30 seconds and run the `kubectl apply` again.

**Verify:**

```bash
kubectl -n metallb-system get pods                  # controller + speaker Running
kubectl -n metallb-system get ipaddresspool,l2advertisement
```

### 3.3 HAProxy ingress controller

DAP expects an ingress class named `haproxy` with **SSL passthrough** enabled — the orchestrator's mTLS
endpoints must receive the client's TLS connection untouched.

```bash
cat > "$WORK_DIR/helm/haproxy-values.yaml" <<'EOF'
controller:
  image:
    pullPolicy: IfNotPresent
  service:
    type: LoadBalancer
    externalTrafficPolicy: Local
  config:
    ssl-passthrough: "true"
  hostNetwork: true
  kind: DaemonSet
  defaultTLSSecret:
     enabled: false
EOF

helm upgrade --install haproxy-ingress haproxytech/kubernetes-ingress \
  --namespace haproxy-controller --create-namespace \
  --version "$HAPROXY_CHART_VERSION" \
  --set controller.image.tag="$HAPROXY_APP_VERSION" \
  -f "$WORK_DIR/helm/haproxy-values.yaml"
```

**Verify:**

```bash
kubectl -n haproxy-controller get pods                 # haproxy-ingress-kubernetes-ingress-xxxxx Running
kubectl -n haproxy-controller get svc                  # TYPE LoadBalancer, EXTERNAL-IP = HOST_IP
kubectl get ingressclass                               # haproxy
curl -sk -o /dev/null -w '%{http_code}\n' https://$HOST_IP/   # 404 - HAProxy answers; no routes yet
```

### 3.4 Longhorn (storage)

Single-node values: one replica per volume (there is nowhere else to put a second copy), and the UI and CSI
side-car pods scaled down to one.

```bash
cat > "$WORK_DIR/helm/longhorn-values.yaml" <<'EOF'
longhornUI:
  replicas: 1
csi:
  attacherReplicaCount: 1
  provisionerReplicaCount: 1
  resizerReplicaCount: 1
  snapshotterReplicaCount: 1
defaultSettings:
  defaultReplicaCount: 1
  storageReservedPercentageForDefaultDisk: 10
  storageOverProvisioningPercentage: 100
  storageMinimalAvailablePercentage: 5
persistence:
  defaultClassReplicaCount: 1
EOF

helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --version "$LONGHORN_VERSION" \
  -f "$WORK_DIR/helm/longhorn-values.yaml"
```

Helm may print a few lines like `Warning: unrecognized format "int64"` while it installs Longhorn's CRDs.
They are harmless: the Kubernetes client doesn't know that schema format name and ignores it. The release
still ends with `STATUS: deployed`.

Longhorn takes 3–5 minutes to come up. Wait for all of its pods:

```bash
kubectl -n longhorn-system get pods -w      # Ctrl+C once everything is Running
```

Then check that Longhorn's CSI driver registered with the kubelet. If the node shows no driver after a few
minutes, restart the plugin (a known Longhorn quirk):

```bash
kubectl get csinode -o custom-columns=NODE:.metadata.name,DRIVERS:.spec.drivers[*].name
# expected: driver.longhorn.io in the DRIVERS column. If not, after ~2 minutes:
# kubectl -n longhorn-system rollout restart daemonset/longhorn-csi-plugin
```

Optional — the `longhornctl` CLI, which can check the node's Longhorn prerequisites:

```bash
curl -fL "https://github.com/longhorn/cli/releases/download/v${LONGHORN_VERSION}/longhornctl-linux-amd64" -o /usr/local/bin/longhornctl
chmod 0755 /usr/local/bin/longhornctl
longhornctl --kubeconfig /etc/rancher/rke2/rke2.yaml check preflight
```

`longhornctl` does not read `~/.kube/config`, so give it the kubeconfig (or `export
KUBECONFIG=/etc/rancher/rke2/rke2.yaml` first). Expect **no `error:` section**. On this single-node setup these
lines are normal:

- `info: [IscsidService] Service iscsid is inactive, but it can still be activated by iscsid.socket` —
  Step 1.7 enabled the socket; iscsid starts on first use.
- `info: [MultipathService] ... multipathd ... is inactive` / `not running` — expected, Step 1.6 masked it.
- `warn: [KubeDNS] ... fewer than 2 replicas` — one node, one CoreDNS; ignore it.

**Verify:**

```bash
kubectl -n longhorn-system get pods | grep -vE 'Running|Completed'   # only the header line
kubectl get storageclass                                             # longhorn (default)
```

Optional — `k9s`, a terminal UI for watching the cluster:

```bash
curl -fL https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz -o "$WORK_DIR/k9s.tar.gz"
tar -xzf "$WORK_DIR/k9s.tar.gz" -C "$WORK_DIR" k9s && install -m 0755 "$WORK_DIR/k9s" /usr/local/bin/k9s
rm -f "$WORK_DIR/k9s" "$WORK_DIR/k9s.tar.gz"
```

---

## Step 4 — Trust the registry and install Docker

### 4.1 Trust the registry's certificate

Dell's installers need the registry's certificate as a file, and the host (Docker and RKE2's containerd) must
trust it. This fetches the certificate chain the registry presents and adds it to the system trust store:

```bash
REG_HOST="${REGISTRY%%:*}"
REG_PORT="${REGISTRY##*:}"
openssl s_client -showcerts -connect "$REG_HOST:$REG_PORT" -servername "$REG_HOST" </dev/null 2>/dev/null \
  | awk '/-----BEGIN CERTIFICATE-----/{c=1} c{print} /-----END CERTIFICATE-----/{c=0}' \
  > "/usr/local/share/ca-certificates/$REG_HOST.crt"
openssl x509 -in "/usr/local/share/ca-certificates/$REG_HOST.crt" -noout -subject -issuer -enddate
update-ca-certificates

echo "export REG_CERT_FILE=\"/usr/local/share/ca-certificates/$REG_HOST.crt\"" >> /root/dap-install.env
source /root/dap-install.env
```

> **Have the CA file already?** If your registry uses a private CA and you have its `ca.crt`, copy that file to
> `/usr/local/share/ca-certificates/<registry-host>.crt` instead of fetching the chain, then run
> `update-ca-certificates`.

Restart RKE2 so its containerd picks up the new trust store:

```bash
systemctl restart rke2-server
kubectl get nodes      # wait until it is Ready again (about a minute)
```

### 4.2 Install Docker

Dell's image loaders run as Docker containers and push with `docker push`. Install Docker CE from Docker's
repository. The `bip` setting moves Docker's bridge network to `172.30.0.1/16` so it can't collide with
common LAN ranges:

```bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "bip": "172.30.0.1/16"
}
EOF

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
```

### Verify

```bash
docker version --format '{{.Server.Version}}'                    # prints a version
echo "$REG_PASS" | docker login "$REGISTRY" -u "$REG_USER" --password-stdin   # Login Succeeded

# A login succeeds even if the project doesn't exist, so prove you can push into REG_PROJECT:
docker pull -q busybox:1.37.0
docker tag busybox:1.37.0 "$REGISTRY/$REG_PROJECT/busybox:pushtest"
docker push "$REGISTRY/$REG_PROJECT/busybox:pushtest"            # ends with "pushtest: digest: sha256:..."
docker rmi "$REGISTRY/$REG_PROJECT/busybox:pushtest" busybox:1.37.0
docker logout "$REGISTRY"
```

A `x509: certificate signed by unknown authority` error here means the certificate step did not work —
redo 4.1, then `systemctl restart docker`. A push error such as `project ... not found`, `denied` or
`unauthorized` means `REG_PROJECT` doesn't match a project in the registry, or `REG_USER` can't push to it —
fix the project or `/root/dap-install.env` now. You can delete the `busybox` repository from the project
afterwards; Dell's installer pushes its own copy.

---

## Step 5 — Install Dell Automation Platform

### 5.1 Download the bundle

`dl.dell.com` rejects downloads that don't look like a browser, so pass a browser user-agent:

```bash
cd "$WORK_DIR"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3"
curl -fL --retry 3 -C - --user-agent "$UA" \
  -o Dell_Automation_Platform_Linux_2.1.1.0.zip \
  https://dl.dell.com/FOLDER14962193M/1/Dell_Automation_Platform_Linux_2.1.1.0.zip
```

If the download is interrupted, run the same command again — `-C -` resumes it. Already have the zip? Copy it
into `$WORK_DIR` instead (for example `scp Dell_Automation_Platform_Linux_2.1.1.0.zip root@<HOST_IP>:/opt/dap-install/`).

### 5.2 Check and extract the bundle

Check the file is complete. Compare the checksum with the one on Dell's download page; for reference, the
2.1.1.0 zip this guide was tested with has the MD5 below and is 16,391,112,969 bytes.

```bash
ls -l Dell_Automation_Platform_Linux_2.1.1.0.zip
md5sum Dell_Automation_Platform_Linux_2.1.1.0.zip    # 4c17f64b857d0aca63d30cbbb7f0ae09
```

Dell ships a signed **outer** zip that wraps the real bundle zip, its signature and Dell's public key. Unzip
the outer zip, verify the signature, then unzip the inner zip:

```bash
mkdir -p "$WORK_DIR/dap-bundle" && cd "$WORK_DIR/dap-bundle"
unzip -o ../Dell_Automation_Platform_Linux_2.1.1.0.zip
ls    # DellAutomationPlatform_v2.1.1.0-<build>.zip, its .signed.bin, dell_public.key

INNER=$(ls DellAutomationPlatform_v*.zip)
openssl dgst -sha384 -verify dell_public.key -signature "$INNER.signed.bin" "$INNER"   # Verified OK

unzip -o "$INNER" && rm -f "$INNER"
chmod +x install-upgrade.sh
ls     # install-upgrade.sh, editEO.sh, editPortal.sh, plus the hidden .resources/ directory
```

### 5.3 Check the cluster can take DAP

DAP's installer checks the node's **allocatable** resources and stops if they are too low. See what the node
reports:

```bash
kubectl get node -o jsonpath='{range .items[*]}cpu={.status.allocatable.cpu} memory={.status.allocatable.memory} ephemeral-storage={.status.allocatable.ephemeral-storage}{"\n"}{end}'
```

You need at least `cpu=12`, `memory` ≥ 24 GiB (36 GB provisioned leaves room for DDPC as well) and
`ephemeral-storage` ≥ 850 GiB (≈ 912,680,550,400 bytes). Also make sure every pod is healthy:

```bash
kubectl get pods -A --no-headers | grep -vE 'Running|Completed'    # no output
```

### 5.4 Run the DAP installer

This is the long step: the installer loads about 16 GB of images, pushes them to your registry, then
installs the Orchestrator and the Portal. Expect **30–60 minutes**. Run it in `screen` so it survives an SSH
disconnect:

```bash
screen -S dap-install
# (inside screen)
source /root/dap-install.env
cd "$WORK_DIR/dap-bundle"
./install-upgrade.sh \
  EO_HOST="orchestrator.$HOST_FQDN" \
  PORTAL_HOST="portal.$HOST_FQDN" \
  PORTAL_COOKIE_DOMAIN="$BASE_DOMAIN" \
  IMAGE_REG_URL="$REGISTRY/$REG_PROJECT" \
  IMAGE_REG_USERNAME="$REG_USER" \
  IMAGE_REG_PASSWORD="$REG_PASS" \
  REGISTRY_CERT_FILE_PATH="$REG_CERT_FILE" \
  SKIP_IMAGES_LOADER="false" \
  IMAGE_LOADER_THREAD_COUNT="5" \
  NAMESPACE="dell-orchestrator" \
  PORTAL_NAMESPACE="dell-portal" \
  PORTAL_INGRESS_CLASS_NAME="haproxy" \
  ORG_NAME="$ORG_NAME" \
  ORG_DESC="$ORG_DESC" \
  FIRST_NAME="$FIRST_NAME" \
  LAST_NAME="$LAST_NAME" \
  USERNAME="$ADMIN_USERNAME" \
  EMAIL="$ADMIN_EMAIL" 2>&1 | tee "$WORK_DIR/dap-install.log"
```

To leave `screen` running, press **Ctrl+A** then **D**. Reattach later with `screen -r dap-install`.

About the parameters:

| Parameter | Meaning |
|:--|:--|
| `EO_HOST` / `PORTAL_HOST` | The orchestrator and portal names from your DNS records |
| `PORTAL_COOKIE_DOMAIN` | The domain the portal login cookie is valid for |
| `IMAGE_REG_URL` | `<registry>:<port>/<project>` — **no** `https://` |
| `REGISTRY_CERT_FILE_PATH` | The certificate file from Step 4.1 |
| `SKIP_IMAGES_LOADER` | `false` = push the bundle's images to the registry. Use `true` only when the same version's images are already in that project |
| `IMAGE_LOADER_THREAD_COUNT` | Parallel image pushes (default 5, maximum 20). The push is most of the install time; a higher value helps if your registry and network can take it |
| `NAMESPACE` / `PORTAL_NAMESPACE` | Kubernetes namespaces for the orchestrator and the portal |
| `PORTAL_INGRESS_CLASS_NAME` | Must be `haproxy` — the ingress class from Step 3.3 |
| `ORG_*`, `FIRST_NAME`, `LAST_NAME`, `USERNAME`, `EMAIL` | The organization and the first administrator |

> The installer rejects any parameter it does not know. Keep the names exactly as shown, and keep each value
> in double quotes so values with spaces (like `ORG_DESC`) arrive in one piece.

While it runs you can watch progress from a second SSH session:

```bash
sudo -i
docker logs -f eo-images-loader                 # the image loader's progress, during the push phase
kubectl get pods -n dell-orchestrator -w        # pods appearing, during the install phase
```

The installer ends with a success summary that includes the portal URL and the initial login.

**If the installer fails, fix the cause and clean up before you run it again.** It saves its progress in a
`checkpoint-data` ConfigMap, and in this non-interactive mode it **resumes from that checkpoint** without
asking. A resumed run skips the step that applies your parameters, so a corrected value (for example
`REG_PROJECT`) would be ignored. If the failure happened before any Helm release was installed (`helm ls -A`
shows no `native-edge-orchestrator` or `dap-portal`), start clean:

```bash
source /root/dap-install.env
kubectl delete namespace dell-orchestrator dell-portal --wait=true   # only the installer's secrets and checkpoint are in them at this point
docker rm -f eo-images-loader 2>/dev/null
# then run the Step 5.4 command again
```

If a Helm release was already installed, see [Troubleshooting](#troubleshooting) and Dell's log collector
before you retry.

### 5.5 Verify DAP

```bash
helm ls -n dell-orchestrator     # native-edge-orchestrator ... deployed ... 2.1.1.0
helm ls -n dell-portal           # dap-portal ... deployed
kubectl get pods -n dell-orchestrator --no-headers | grep -vE 'Running|Completed'   # no output
kubectl get pods -n dell-portal       --no-headers | grep -vE 'Running|Completed'   # no output
kubectl get ingress -A           # hosts portal.<HOST_FQDN>, orchestrator.<HOST_FQDN>, mtls-* names
curl -sk -o /dev/null -w '%{http_code}\n' https://portal.$HOST_FQDN/        # 200 or 30x
curl -sk -o /dev/null -w '%{http_code}\n' https://orchestrator.$HOST_FQDN/  # 30x
```

Once DAP checks out, close the `screen` session (the log is already saved in `$WORK_DIR/dap-install.log`):

```bash
screen -ls                          # lists dap-install
screen -S dap-install -X quit       # or: screen -r dap-install, then type exit
```

### 5.6 First login — change the password now

1. Open `https://portal.<HOST_FQDN>` in a browser and accept the self-signed certificate warning.
2. Sign in as **`<ADMIN_USERNAME>`** with the password **`Temporary@123`**.
3. Set a new password when prompted. **Do this before the portal is reachable by anyone else.**

---

## Step 6 — Install Dell Distributed Private Cloud

DDPC is an add-on that installs **into** the running DAP orchestrator (same cluster, same `dell-orchestrator`
namespace). It requires DAP **2.1.1.0** exactly.

### 6.1 Pre-checks

```bash
# DAP orchestrator is deployed at 2.1.1.0, and the portal is deployed
helm ls -n dell-orchestrator -o json | jq -r '.[] | select(.chart|startswith("native-edge-orchestrator")) | "\(.status) \(.app_version)"'   # deployed 2.1.1.0
helm ls -n dell-portal -o json | jq -r '.[] | select(.chart|startswith("dap-portal")) | .status'   # deployed

# The orchestrator ingress serves the name you will pass as DAPO_HOST
kubectl -n dell-orchestrator get ingress -o jsonpath='{.items[*].spec.rules[*].host}' | tr ' ' '\n' | grep -x "orchestrator.$HOST_FQDN"

# Free headroom: allocatable minus requested - DDPC needs about 2 CPU and 4 GiB free
kubectl describe node | sed -n '/Allocated resources/,/Events/p'
```

**Clean up failed attempt pods.** During the DAP install some Jobs fail on their first attempt (for example
`postgresql-credentials-bootstrap` runs before PostgreSQL is up), retry, and then complete. The failed
attempt's pod stays behind in `Error` state. List the pods that are not Running/Completed, check that each
belongs to a Job that **did** complete, and delete them:

```bash
kubectl get pods -A --no-headers | grep -vE 'Running|Completed'
kubectl -n dell-orchestrator get jobs        # the matching Job shows COMPLETIONS 1/1 (or STATUS Complete)
kubectl -n dell-orchestrator delete pod <failed-attempt-pod-name>
```

If a pod in `Error` belongs to a Job that never completed, stop and fix DAP first — don't install DDPC on top
of a broken DAP.

### 6.2 Download, check and extract the bundle

```bash
cd "$WORK_DIR"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/58.0.3029.110 Safari/537.3"
curl -fL --retry 3 -C - --user-agent "$UA" \
  -o dell-distributed-private-cloud_4.3.0.0.zip \
  https://dl.dell.com/FOLDER14941030M/1/dell-distributed-private-cloud_4.3.0.0.zip

sha256sum dell-distributed-private-cloud_4.3.0.0.zip
# tested copy: 35191b871a7a8fca64f68d187864bc72b2179c2dfbe451ba47ea056c33424b69 (6,248,535,789 bytes)

mkdir -p "$WORK_DIR/ddpc-bundle" && cd "$WORK_DIR/ddpc-bundle"
unzip -o ../dell-distributed-private-cloud_4.3.0.0.zip
INNER=$(ls dell-distributed-private-cloud_*.zip)
openssl dgst -sha384 -verify dell_public.key -signature "$INNER.signed.bin" "$INNER"   # Verified OK
unzip -o "$INNER" && rm -f "$INNER"
chmod +x install-upgrade.sh
ls -a      # install-upgrade.sh and the hidden .resources/ directory
```

### 6.3 Run the DDPC installer

About **10 minutes** (it pushes 19 images, about 6 GB, then installs a Helm release). Run it in `screen`:

```bash
screen -S ddpc-install
# (inside screen)
source /root/dap-install.env
cd "$WORK_DIR/ddpc-bundle"
env IMAGE_LOADER_MAX_RETRIES="3" ./install-upgrade.sh \
  DAPO_HOST="orchestrator.$HOST_FQDN" \
  NAMESPACE="dell-orchestrator" \
  IMAGE_REG_URL="$REGISTRY/$REG_PROJECT" \
  IMAGE_REG_USERNAME="$REG_USER" \
  IMAGE_REG_PASSWORD="$REG_PASS" \
  REGISTRY_CERT_FILE_PATH="$REG_CERT_FILE" \
  SKIP_IMAGES_LOADER="false" \
  IMAGE_LOADER_PARALLEL_JOBS="5" \
  INSTALL_TYPE="KUBERNETES" \
  INSTALL_TIMEOUT="600" 2>&1 | tee "$WORK_DIR/ddpc-install.log"
```

| Parameter | Meaning |
|:--|:--|
| `DAPO_HOST` | The orchestrator name — must match the DAP orchestrator ingress (`orchestrator.<HOST_FQDN>`) |
| `NAMESPACE` | The namespace DAP's orchestrator runs in |
| `IMAGE_REG_URL`, `IMAGE_REG_USERNAME`, `IMAGE_REG_PASSWORD`, `REGISTRY_CERT_FILE_PATH` | Where to push and pull the DDPC images. Give all four or none — with none, the installer reuses the registry credentials DAP stored in the `docker-secret` secret |
| `SKIP_IMAGES_LOADER` | `false` = push the images. A repeat run skips the push on its own once it has succeeded |
| `IMAGE_LOADER_PARALLEL_JOBS` | Parallel image pushes (default 5) |
| `INSTALL_TYPE` | `KUBERNETES` = into this cluster |
| `INSTALL_TIMEOUT` | Helm timeout in seconds |
| `IMAGE_LOADER_MAX_RETRIES` (environment variable) | Retries per image push |

> Like the DAP installer, it rejects unknown parameters and needs every value in double quotes. Add
> `LOG_LEVEL="DEBUG"` after `env` to see the Helm command it runs.

### 6.4 Verify DDPC

```bash
helm ls -n dell-orchestrator    # dell-distributed-private-cloud deployed (4.3.0-...) AND native-edge-orchestrator still deployed 2.1.1.0

kubectl -n dell-orchestrator get deploy hzp-compute-svc hzp-ece-firmwareupdate-svc fido-manufacturer \
  hzp-fru-cru-svc hzp-health-check-svc hzp-oe-template-mgr-svc hzp-recovery-svc hzp-time-svc \
  ne-endpoint-svc ne-ui                                    # all 10 READY 1/1

kubectl -n dell-orchestrator get cm ne-nginx-config ne-interop-config ddpc-version-config   # all three exist
kubectl -n dell-orchestrator get pods -l app=nginx-gw     # AGE younger than the DDPC install (the gateway was restarted to load DDPC's routes)
kubectl get pods -A --no-headers | grep -vE 'Running|Completed'   # no output
```

Close the `screen` session (the log is in `$WORK_DIR/ddpc-install.log`):

```bash
screen -S ddpc-install -X quit
screen -ls                          # "No Sockets found" once both sessions are closed
```

DDPC adds no new DNS names or ingress — its UI and API are routes on the orchestrator. To see it, sign in to
the orchestrator and open `https://orchestrator.<HOST_FQDN>/neui/`.

---

## Step 7 — Final verification

| # | Check | Command | Expected |
|:--|:--|:--|:--|
| 1 | Node ready | `kubectl get nodes` | 1 node, `Ready` |
| 2 | No unhealthy pods | `kubectl get pods -A --no-headers \| grep -vE 'Running\|Completed'` | no output |
| 3 | Built-in NGINX ingress absent | `kubectl get pods -A \| grep -c rke2-ingress-nginx` | `0` |
| 4 | Ingress has the host IP | `kubectl -n haproxy-controller get svc` | `EXTERNAL-IP` = host IP |
| 5 | Storage | `kubectl get sc` | `longhorn (default)` |
| 6 | Volumes healthy | `kubectl -n longhorn-system get volumes.longhorn.io` | every volume `attached` / `healthy` |
| 7 | Helm releases | `helm ls -A` | `metallb`, `haproxy-ingress`, `longhorn`, `native-edge-orchestrator` (2.1.1.0), `dap-portal`, `dell-distributed-private-cloud` — all `deployed` |
| 8 | Host settings | `sysctl fs.inotify.max_user_instances; systemctl is-enabled multipathd` | `1024`, `masked` |
| 9 | Portal | browser → `https://portal.<HOST_FQDN>` | login page; signs in with your new password |
| 10 | mTLS names | `openssl s_client -connect mtls-orchestrator.$HOST_FQDN:443 -servername mtls-orchestrator.$HOST_FQDN </dev/null 2>/dev/null \| grep -m1 subject` | prints a certificate subject (DAP's own certificate, passed straight through HAProxy) |
| 11 | DDPC | `https://orchestrator.<HOST_FQDN>/neui/` after signing in | the DDPC UI |
| 12 | Survives a reboot | `reboot`, then repeat checks 1–2 after ~10 minutes | all pods back to Running |

When everything passes you can delete the extracted bundles to free about 25 GB:
`rm -rf $WORK_DIR/dap-bundle $WORK_DIR/ddpc-bundle` (keep the zips if you may need to reinstall or upgrade).

---

## Troubleshooting

| Symptom | Cause | Fix |
|:--|:--|:--|
| `apt-get` fails with "Could not get lock /var/lib/dpkg/lock-frontend" | cloud-init is still updating packages on a fresh image | `cloud-init status --wait`, then retry |
| CoreDNS in `CrashLoopBackOff`, log says `Loop ... detected` | the kubelet was given a `resolv.conf` that points at `127.0.0.53` | check `resolv-conf=` in `/etc/rancher/rke2/config.yaml` points at `/run/systemd/resolve/resolv.conf` and that file lists real DNS servers; `systemctl restart rke2-server` |
| Pods can't resolve the registry or other LAN names | the host's DNS servers don't know them | fix the host's DNS (`resolvectl status`), then `kubectl -n kube-system rollout restart deploy rke2-coredns-rke2-coredns` |
| Pods stuck `ContainerCreating`, events say `CSINode ... does not contain driver driver.longhorn.io` | Longhorn's CSI plugin didn't register with the kubelet | `kubectl -n longhorn-system rollout restart daemonset/longhorn-csi-plugin` |
| Volume mounts fail with `exit status 32` or `Can't open blockdev` | `multipathd` claimed the Longhorn iSCSI device | redo [Step 1.6](#16-disable-multipathd); reboot the host |
| fluent-bit pods crash with `too many open files` / `errno=24` | inotify limits not raised | redo [Step 1.5](#15-kernel-settings) |
| `install-upgrade.sh` says a parameter is invalid | a misspelled or unquoted parameter | compare with the command block; every value in double quotes, no spaces around `=` |
| DAP install stops with not enough CPU / memory / disk | the node's allocatable resources are under DAP's minimum (12 CPU, 24 GiB, 850 GiB ephemeral-storage) | see [Step 5.3](#53-check-the-cluster-can-take-dap); grow the VM or its disk, then reboot so Kubernetes re-reads the sizes |
| `docker login` or the image push fails with `x509: certificate signed by unknown authority` | the registry certificate is not trusted | redo [Step 4.1](#41-trust-the-registrys-certificate), `systemctl restart docker rke2-server` |
| Pods in `ImagePullBackOff` from your registry | images not pushed, wrong project, or containerd doesn't trust the registry | check the project contains the images; check `IMAGE_REG_URL`; `systemctl restart rke2-server` after a certificate change |
| The DAP install stops after `Pushing 116 images` with `failed to push image <registry>/<project>/busybox:1.37.0 ... exit status 125` and `EO Image Loader has failed ... Error code: 0x016030005` | the project in `IMAGE_REG_URL` doesn't exist in the registry (often a typo in `REG_PROJECT`), or the user can't push to it. The loader log only shows `exit status 125` | run the test push from [Step 4.2](#42-install-docker); fix the project name or the user's rights; clean up and re-run as described at the end of [Step 5.4](#54-run-the-dap-installer) |
| The image push is very slow | registry or network throughput | raise `IMAGE_LOADER_THREAD_COUNT` (up to 20) and re-run; already-pushed images are skipped |
| Browser refuses the portal certificate with no "proceed anyway" option | the domain uses an HSTS-preloaded TLD (`.dev`, `.app`, …) | use a different domain; this can't be fixed on the DAP side |
| A pod in `Error` blocks the DDPC pre-checks | a failed first attempt of a Job that later completed | see [Step 6.1](#61-pre-checks); delete the stale pod |
| The SSH session dropped during the install | long-running command over an unstable session | reconnect, `sudo -i`, `screen -r dap-install` (or `ddpc-install`) |

**Collecting logs for Dell support:** Dell publishes a log-collector tool in knowledge-base article
**000216838** (`https://supportkb.dell.com/attachment/ka0Do000000iqQzIAI/logs_pkb_en_US_1.zip`). Also keep
`$WORK_DIR/dap-install.log` and `$WORK_DIR/ddpc-install.log`.

---

## Appendix A — Uninstall and clean-up

This removes **everything**, including all DAP data. There is no undo.

```bash
sudo -i
source /root/dap-install.env

# 1. Kubernetes and everything running in it (DAP, DDPC, Longhorn, MetalLB, HAProxy)
/usr/local/bin/rke2-uninstall.sh
rm -rf /var/lib/longhorn /etc/rancher /root/.kube /etc/profile.d/rke2.sh
rm -f /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr

# 2. Tools
rm -f /usr/local/bin/helm /usr/local/bin/longhornctl /usr/local/bin/k9s
rm -rf /root/.config/helm /root/.cache/helm

# 3. Docker
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
rm -rf /var/lib/docker /var/lib/containerd /etc/docker
rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc

# 4. Registry trust
rm -f "$REG_CERT_FILE" && update-ca-certificates --fresh

# 5. Host settings from Step 1
rm -f /etc/sysctl.d/10-ap-orchestrator.conf /etc/sysctl.d/40-k8s.conf /etc/modules-load.d/40-k8s.conf
systemctl restart systemd-sysctl
rm -f /etc/multipath/conf.d/99-dap.conf
systemctl unmask multipathd.service multipathd.socket
systemctl enable --now multipathd.service multipathd.socket

# 6. Bundles and this guide's working files
rm -rf "$WORK_DIR" /root/dap-install.env
```

Packages installed in Step 1.2 are left in place (they are harmless); remove them with `apt-get purge` if you
want to. Swap and the firewall stay off — re-enable them only if the host is no longer a Kubernetes node.

> To remove **only DDPC** and keep DAP, uninstall its Helm release:
> `helm uninstall dell-distributed-private-cloud -n dell-orchestrator`. Its config maps (`distpvtcloud-*`,
> `ne-*-config`, `ddpc-version-config`) and the `distpvtcloud-docker-secret` secret are left behind and can be
> deleted with `kubectl -n dell-orchestrator delete`.

---

## Appendix B — How these steps map to ap-tools

If you later switch to the script (or compare a manual host with a scripted one), this is where each manual
step lives in `ap-tools` and `rke2_installer.sh`. Variable names in brackets are the ap-tools settings that
change the same thing.

| Manual step | ap-tools / rke2_installer.sh |
|:--|:--|
| 1.2 packages | `run_install_join_push` → `install_packages.sh online jq zip unzip hostname bc openssl` + `set_longhorn_packages` |
| 1.3–1.4, 1.8 modules, swap, firewall | `rke2_installer.sh` host preparation |
| 1.5 inotify sysctl, 1.6 multipathd | `configure_node_sysctl` |
| 1.7 iscsid | `enable_iscsid` |
| 2.1 RKE2 config | `rke2_installer.sh` `render_rke2_config` [`RKE2_VERSION`, `CNI_TYPE`, `MAX_PODS`, `CLUSTER_CIDR`, `SERVICE_CIDR`, `-tls-san`] |
| 2.2 CoreDNS | `rke2_installer.sh` `create_config_files` |
| 3.1 Helm | `install_helm` [`HELM_VERSION`] |
| 3.2 MetalLB | `helm_install_metallb` [`METALLB_VERSION`, `LB_IP`] |
| 3.3 HAProxy | `helm_install_haproxy` [`KUBERNETES_INGRESS_VERSION`, `HAPROXY_APP_VERSION`] |
| 3.4 Longhorn | `helm_install_longhorn` + `verify_longhorn_csi_registration` [`LONGHORN_VERSION`] |
| 4.1–4.2 registry trust, Docker | `install_reg_docker` (`image_pull_push.sh reg-cert` + `docker`) |
| 5.1–5.2 DAP bundle | `download_dell_bundle` + `extract_dell_bundle` [`AP_BUNDLE_URL`] |
| 5.3 resource check | `ap_preflight_checks` |
| 5.4 DAP command block | `runtime_outputs` → `ap-install-upgrade-cmd.txt` [`ORG_NAME`, `USERNAME`, `EMAIL`, `SKIP_IMAGES_LOADER`, `IMAGE_LOADER_THREAD_COUNT`, …] |
| 6.1 DDPC pre-checks | `ddpc_preflight_checks` |
| 6.2–6.3 DDPC bundle and command | `ddpc_bundle_prep` → `ddpc-install-upgrade-cmd.txt` [`DDPC_BUNDLE_URL`, `DDPC_*`] |

The scripted equivalent of this whole guide is:

```bash
sudo BASE_DOMAIN=<BASE_DOMAIN> ./ap-tools install rke2 -tls-san <HOST_FQDN>
sudo BASE_DOMAIN=<BASE_DOMAIN> HOST_FQDN=<HOST_FQDN> ORG_NAME=... ./ap-tools install ap-bundle -registry <REGISTRY> <REG_USER> <REG_PASS>
# run the command in ap-install-upgrade-cmd.txt
sudo BASE_DOMAIN=<BASE_DOMAIN> HOST_FQDN=<HOST_FQDN> ./ap-tools install ddpc-bundle -registry <REGISTRY> <REG_USER> <REG_PASS>
# run the command in ddpc-install-upgrade-cmd.txt
```
