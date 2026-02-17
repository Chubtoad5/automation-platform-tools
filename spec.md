# Velero Backup with Longhorn & SeaweedFS S3

> **Environment:** Single-node Kubernetes cluster, Longhorn storage, SeaweedFS S3, Ubuntu 22.04
> **Velero Version:** v1.17.x | **AWS Plugin:** v1.13.x | **CSI plugin:** built-in (since Velero 1.14)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│   Kubernetes Cluster (single-node, Ubuntu 22.04)         │
│                                                          │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Backed up by Velero:                                │ │
│  │  dell-portal ◄──┐    haproxy-controller             │ │
│  │  dell-orchestrator ◄─── (reverse proxy)             │ │
│  │  default          metallb-system (LoadBalancer)     │ │
│  │  + cluster-scoped: CRDs, RBAC, StorageClasses      │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Reinstall fresh on recovery:                        │ │
│  │  kube-system, calico-system, tigera-operator,       │ │
│  │  longhorn-system, velero                            │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌───────────┐  ┌────────────┐                           │
│  │  Velero    │  │ Node Agent │                           │
│  │  Server    │  │ (DaemonSet)│                           │
│  └─────┬─────┘  └──────┬─────┘                           │
│        │               │                                 │
│  ┌─────┴───────────────┴─────┐        ┌────────────────┐ │
│  │   Longhorn CSI Driver     │───────▶│  SeaweedFS S3  │ │
│  │   (VolumeSnapshots)       │        │ velero-backups  │ │
│  └───────────────────────────┘        └────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

**How it works:**

1. Velero backs up all Kubernetes resource manifests from the included namespaces (dell-portal, dell-orchestrator, haproxy-controller, metallb-system, default) plus cluster-scoped resources to the S3 bucket.
2. For PVC data in dell-portal and dell-orchestrator, Velero uses **CSI Snapshot Data Movement**: it creates a CSI VolumeSnapshot via Longhorn, clones it to a temporary PVC, then a data-mover pod uploads the data to S3 using Kopia (built-in).
3. Stateless namespaces (haproxy-controller, metallb-system) are just manifest snapshots — no data movement, near-instant.
4. After upload completes, the temporary snapshots and PVCs are cleaned up automatically.

---

## Understanding Full Cluster Backup (Two Layers)

For true disaster recovery you need **two complementary backup layers**:

| Layer | Tool | What it captures | Restore scenario |
|-------|------|-----------------|------------------|
| **1. Kubernetes state + PVC data** | Velero | All API objects (Deployments, Services, ConfigMaps, Secrets, CRDs, RBAC, Namespaces, PVs, etc.) + persistent volume data | Rebuild apps on a fresh cluster, recover from accidental deletions, namespace-level or full-cluster restore |
| **2. etcd snapshot** | `etcdctl` / K3s snapshot / etc. | Raw cluster database (all API objects, internal state, leader election, etc.) | Restore a broken control plane in-place, recover from etcd corruption |

**What Velero covers (with `--include-cluster-resources=true`):**
- All namespace-scoped resources (Pods, Deployments, Services, ConfigMaps, Secrets, PVCs, etc.)
- All cluster-scoped resources (Namespaces, CRDs, ClusterRoles, ClusterRoleBindings, StorageClasses, PersistentVolumes, IngressClasses, etc.)
- PVC data (via CSI snapshot data movement to S3)

**What Velero does NOT cover:**
- Cluster infrastructure (certificates, kubeconfig, join tokens, CNI config)
- The etcd database itself (Velero reads from the API server, not etcd directly)
- Node-level configuration (kubelet config, containerd config, OS packages)
- Velero itself and Longhorn itself (you don't want to restore these from backup — they need to be installed first on the fresh cluster)

**The `--include-cluster-resources=true` flag** is essential for full recovery. Without it, Velero only includes cluster-scoped resources that are "owned by" or directly referenced by the namespace-scoped resources being backed up. With the flag, you get everything: all CRDs, all RBAC, all StorageClasses, etc.

### Full Disaster Recovery Procedure (high level)

1. Stand up a fresh Kubernetes cluster (same distribution)
2. Restore etcd snapshot (if restoring in-place) — OR — install Longhorn + Velero on the new cluster
3. Point Velero at the same S3 bucket → it auto-discovers existing backups
4. `velero restore create --from-backup <latest>`
5. Verify workloads come up

The etcd snapshot is your belt; Velero is your suspenders. For most recovery scenarios (accidental deletion, namespace corruption, app rollback), Velero alone is sufficient. The etcd snapshot is your safety net for control plane failures.

---

## Prerequisites

- `kubectl` configured and able to reach your cluster
- Longhorn already installed and working as your StorageClass
- SeaweedFS running with S3 API enabled (note down the endpoint URL, access key, and secret key)
- A bucket created in SeaweedFS for Velero backups
- Kubernetes CSI Snapshot CRDs and snapshot controller installed (Longhorn usually installs these—verify below)

---

## Step 1: Verify CSI Snapshot Support

Longhorn supports CSI snapshots, but the VolumeSnapshot CRDs and snapshot controller must be present.

```bash
# Check if VolumeSnapshot CRDs exist
kubectl get crd | grep volumesnapshot
```

You should see:
```
volumesnapshotclasses.snapshot.storage.k8s.io
volumesnapshotcontents.snapshot.storage.k8s.io
volumesnapshots.snapshot.storage.k8s.io
```

If they're **missing**, install them:

```bash
# Install snapshot CRDs (check for the latest version tag at https://github.com/kubernetes-csi/external-snapshotter)
SNAPSHOTTER_VERSION="v8.2.0"

kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml

# Install the snapshot controller (if not already present)
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

Verify the controller is running:
```bash
kubectl get pods -n kube-system | grep snapshot-controller
```

---

## Step 2: Create a VolumeSnapshotClass for Longhorn

This tells Velero which snapshot class to use for Longhorn-provisioned PVCs.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: longhorn-snapshot-vsc
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: driver.longhorn.io
deletionPolicy: Delete
parameters:
  type: snap
EOF
```

Key points:
- The label `velero.io/csi-volumesnapshot-class: "true"` tells Velero to automatically use this class for Longhorn volumes.
- `type: snap` creates an in-cluster Longhorn snapshot (fast). Velero's data mover handles uploading to S3.
- `deletionPolicy: Delete` ensures snapshot resources are cleaned up after backup completes.

---

## Step 3: Create the S3 Bucket in SeaweedFS

If you haven't already, create a dedicated bucket. You can use the `aws` CLI pointed at your SeaweedFS endpoint, or the SeaweedFS shell/UI.

```bash
# Example using aws CLI (install with: sudo apt install awscli)
aws s3 mb s3://velero-backups \
  --endpoint-url http://<SEAWEEDFS_S3_ENDPOINT>:8333

# Verify
aws s3 ls --endpoint-url http://<SEAWEEDFS_S3_ENDPOINT>:8333
```

Replace `<SEAWEEDFS_S3_ENDPOINT>` with your SeaweedFS server IP or hostname, and adjust the port if different.

---

## Step 4: Install the Velero CLI

```bash
# Set the version (check https://github.com/vmware-tanzu/velero/releases for latest)
VELERO_VERSION="v1.17.1"

# Download
wget -q https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz

# Extract and install
tar -xzf velero-${VELERO_VERSION}-linux-amd64.tar.gz
sudo mv velero-${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/

# Verify
velero version --client-only

# Cleanup
rm -rf velero-${VELERO_VERSION}-linux-amd64*
```

---

## Step 5: Create the S3 Credentials File

```bash
cat > /tmp/credentials-velero <<EOF
[default]
aws_access_key_id=<YOUR_SEAWEEDFS_ACCESS_KEY>
aws_secret_access_key=<YOUR_SEAWEEDFS_SECRET_KEY>
EOF
```

Replace the placeholder values with your actual SeaweedFS S3 credentials.

---

## Step 6: Install Velero into the Cluster

This single command installs Velero with CSI support and the node agent for data movement:

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.13.0 \
  --bucket velero-backups \
  --backup-location-config \
    region=us-east-1,s3ForcePathStyle=true,s3Url=http://<SEAWEEDFS_S3_ENDPOINT>:8333,checksumAlgorithm="" \
  --secret-file /tmp/credentials-velero \
  --features=EnableCSI \
  --use-node-agent \
  --use-volume-snapshots=true \
  --wait
```

**Flag breakdown:**

| Flag | Purpose |
|------|---------|
| `--provider aws` | Uses the AWS/S3-compatible plugin |
| `--plugins velero/velero-plugin-for-aws:v1.13.0` | S3 object store plugin |
| `--bucket velero-backups` | Your SeaweedFS bucket name |
| `region=us-east-1` | Required by the plugin but arbitrary for SeaweedFS |
| `s3ForcePathStyle=true` | **Critical for non-AWS S3** — uses path-style URLs |
| `s3Url=http://...` | Your SeaweedFS S3 endpoint |
| `checksumAlgorithm=""` | Disables checksum (some S3-compatible stores don't support it) |
| `--features=EnableCSI` | Enables CSI snapshot integration |
| `--use-node-agent` | Installs the node agent DaemonSet for data movement |
| `--use-volume-snapshots=true` | Enables volume snapshot support |

> **Note on `checksumAlgorithm=""`**: SeaweedFS may not support all S3 checksum algorithms. If you see `NotImplemented` errors during backup, this flag resolves it. If your SeaweedFS version supports checksums, you can omit it.

> **HTTPS/Self-signed certs**: If your SeaweedFS uses HTTPS with a self-signed certificate, add `--cacert /path/to/ca.pem` to the install command.

---

## Step 7: Verify the Installation

```bash
# Check Velero pods
kubectl get pods -n velero

# Expected output (single-node cluster):
# NAME                      READY   STATUS    RESTARTS   AGE
# node-agent-xxxxx          1/1     Running   0          1m
# velero-xxxxxxxxxx-xxxxx   1/1     Running   0          1m

# Verify backup storage location is available
velero backup-location get

# Expected: STATUS should show "Available"
```

If the backup location shows `Unavailable`, check:
```bash
# View Velero logs for S3 connection issues
kubectl logs deployment/velero -n velero | tail -50
```

Common issues: wrong endpoint URL, credentials, bucket doesn't exist, or network/firewall blocking access.

---

## Step 8: Run a Test Backup

### Create a test workload

```bash
# Create a test namespace with a PVC-backed pod
kubectl create namespace velero-test

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
  namespace: velero-test
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: velero-test
spec:
  containers:
  - name: busybox
    image: busybox
    command: ["sh", "-c", "echo 'Velero backup test data' > /data/testfile.txt && sleep 3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-pvc
EOF

# Wait for pod to be ready
kubectl wait --for=condition=ready pod/test-pod -n velero-test --timeout=120s
```

### Run the backup with data movement

```bash
velero backup create test-backup \
  --include-namespaces velero-test \
  --snapshot-move-data \
  --wait
```

The `--snapshot-move-data` flag is the key — it tells Velero to:
1. Create a CSI snapshot of each PVC
2. Clone the snapshot to a temporary PVC
3. Upload the data to S3 via the built-in Kopia data mover
4. Clean up the snapshot and temporary PVC

### Monitor progress

```bash
# Watch backup status
velero backup describe test-backup --details

# Check data upload progress
kubectl get datauploads -n velero

# View logs if needed
velero backup logs test-backup
```

### Verify the backup succeeded

```bash
velero backup get
# Should show: STATUS = Completed, ERRORS = 0
```

### Run a full cluster backup (production)

Once the test passes, try a full cluster backup with your actual workloads:

```bash
velero backup create full-cluster-$(date +%Y%m%d) \
  --include-namespaces default,dell-portal,dell-orchestrator,haproxy-controller,metallb-system \
  --include-cluster-resources=true \
  --snapshot-move-data \
  --wait
```

This captures your five workload namespaces plus all cluster-scoped resources. PVC data from dell-portal and dell-orchestrator is uploaded to S3. The stateless namespaces (haproxy, metallb, default) are just manifest snapshots.

---

## Step 9: Test a Restore

```bash
# Delete the test namespace to simulate disaster
kubectl delete namespace velero-test

# Wait for it to be fully gone
kubectl wait --for=delete namespace/velero-test --timeout=60s 2>/dev/null; true

# Restore from backup
velero restore create --from-backup test-backup --wait

# Verify restoration
kubectl get pods -n velero-test
kubectl exec -n velero-test test-pod -- cat /data/testfile.txt
# Should output: "Velero backup test data"
```

### Clean up test resources

```bash
kubectl delete namespace velero-test
velero backup delete test-backup --confirm
```

---

## Step 10: Set Up Scheduled Backups

Your cluster namespace layout:

| Namespace | Contents | Backup? | PVC Data? |
|-----------|----------|---------|-----------|
| `default` | Your resources | Yes | No |
| `dell-portal` | Dell portal app | Yes | **Yes** |
| `dell-orchestrator` | Dell orchestrator app | Yes | **Yes** |
| `haproxy-controller` | Reverse proxy for dell-* | Yes | No |
| `metallb-system` | LoadBalancer for dell-* | Yes | No |
| `kube-system` | K8s core | **Reinstall** | — |
| `kube-public` | K8s core | **Reinstall** | — |
| `kube-node-lease` | K8s core | **Reinstall** | — |
| `calico-system` | CNI | **Reinstall** | — |
| `tigera-operator` | Calico operator | **Reinstall** | — |
| `longhorn-system` | Storage provider | **Reinstall** | — |
| `velero` | Backup tool | **Reinstall** | — |

```bash
# Daily full backup at 2 AM, retained for 30 days
velero schedule create daily-full-backup \
  --schedule="0 2 * * *" \
  --ttl 720h \
  --snapshot-move-data \
  --include-cluster-resources=true \
  --include-namespaces default,dell-portal,dell-orchestrator,haproxy-controller,metallb-system
```

What this captures:

- **dell-portal & dell-orchestrator**: All manifests + PVC data uploaded to S3 via CSI snapshot data movement
- **haproxy-controller**: Deployment, ConfigMaps, Services, any Ingress resources — the full routing config
- **metallb-system**: The MetalLB Deployments + CRD instances (`IPAddressPool`, `L2Advertisement`) that define your IP ranges
- **default**: Any resources you've placed in the default namespace
- **Cluster-scoped resources**: CRDs, ClusterRoles, ClusterRoleBindings, StorageClasses, IngressClasses, etc.

The stateless namespaces (haproxy, metallb) add negligible backup time/size since there's no PVC data to move — Velero just snapshots the YAML manifests.

> **Why explicitly list namespaces instead of `--include-namespaces='*' --exclude-namespaces ...`?**
> With an explicit include list, any new infrastructure namespace someone adds later won't
> accidentally get backed up and cause restore conflicts. You're in control of exactly what
> gets protected. When you add a new workload namespace in the future, add it to this list.

Verify the schedule:
```bash
velero schedule get

# Run a manual backup to test the schedule config
velero backup create manual-full-$(date +%Y%m%d) \
  --from-schedule daily-full-backup \
  --wait

velero backup describe manual-full-$(date +%Y%m%d) --details
```

---

## Step 11: etcd Snapshot Backup (Complementary)

This is the second layer of your disaster recovery strategy. The exact command depends on your Kubernetes distribution.

### kubeadm clusters

```bash
# Take an etcd snapshot
sudo ETCDCTL_API=3 etcdctl snapshot save /opt/etcd-backups/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify the snapshot
sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backups/etcd-snapshot-*.db --write-table
```

### K3s clusters

```bash
# K3s has a built-in snapshot command
sudo k3s etcd-snapshot save --name manual-$(date +%Y%m%d-%H%M%S)

# Snapshots are saved to /var/lib/rancher/k3s/server/db/snapshots/ by default
# K3s also takes automatic snapshots (configured via --etcd-snapshot-schedule-cron)
ls /var/lib/rancher/k3s/server/db/snapshots/
```

### RKE2 clusters

```bash
# RKE2 also has built-in snapshots
sudo rke2 etcd-snapshot save --name manual-$(date +%Y%m%d-%H%M%S)

# Default location: /var/lib/rancher/rke2/server/db/snapshots/
```

### Automate and offload to S3

Create a simple cron job to take etcd snapshots and upload them to your SeaweedFS S3:

```bash
#!/bin/bash
# /opt/scripts/etcd-backup.sh — adapt the snapshot command for your distro
set -euo pipefail

BACKUP_DIR="/opt/etcd-backups"
S3_BUCKET="s3://velero-backups/etcd-snapshots"
S3_ENDPOINT="http://<SEAWEEDFS_S3_ENDPOINT>:8333"
RETENTION_DAYS=30

mkdir -p "$BACKUP_DIR"
SNAPSHOT_FILE="$BACKUP_DIR/etcd-snapshot-$(date +%Y%m%d-%H%M%S).db"

# === Choose ONE of these based on your distro ===
# kubeadm:
ETCDCTL_API=3 etcdctl snapshot save "$SNAPSHOT_FILE" \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# k3s (uncomment and use instead):
# k3s etcd-snapshot save --name "manual-$(date +%Y%m%d-%H%M%S)"
# SNAPSHOT_FILE=$(ls -t /var/lib/rancher/k3s/server/db/snapshots/ | head -1)
# SNAPSHOT_FILE="/var/lib/rancher/k3s/server/db/snapshots/$SNAPSHOT_FILE"
# ================================================

# Upload to S3
aws s3 cp "$SNAPSHOT_FILE" "$S3_BUCKET/" --endpoint-url "$S3_ENDPOINT"

# Clean up local snapshots older than retention period
find "$BACKUP_DIR" -name "etcd-snapshot-*.db" -mtime +${RETENTION_DAYS} -delete

echo "etcd snapshot completed and uploaded: $(basename $SNAPSHOT_FILE)"
```

```bash
# Make executable and add to cron (every 6 hours)
chmod +x /opt/scripts/etcd-backup.sh
echo "0 */6 * * * root /opt/scripts/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1" | sudo tee /etc/cron.d/etcd-backup
```

### Also back up certificates and cluster config

```bash
# Back up Kubernetes PKI (critical for cluster identity)
sudo tar czf /opt/etcd-backups/k8s-pki-$(date +%Y%m%d).tar.gz /etc/kubernetes/pki/

# Upload to S3
aws s3 cp /opt/etcd-backups/k8s-pki-*.tar.gz \
  s3://velero-backups/cluster-config/ \
  --endpoint-url http://<SEAWEEDFS_S3_ENDPOINT>:8333

# For K3s, the relevant files are:
# sudo tar czf /opt/etcd-backups/k3s-config-$(date +%Y%m%d).tar.gz \
#   /var/lib/rancher/k3s/server/token \
#   /var/lib/rancher/k3s/server/tls/
```

---

## Operational Commands Reference

```bash
# List all backups
velero backup get

# Describe a specific backup with details
velero backup describe <backup-name> --details

# View backup logs
velero backup logs <backup-name>

# Create an on-demand backup of a single namespace
velero backup create my-backup --include-namespaces <ns> --snapshot-move-data

# Restore to a different namespace
velero restore create --from-backup <backup-name> \
  --namespace-mappings old-ns:new-ns

# Delete a backup (removes from S3 too)
velero backup delete <backup-name> --confirm

# List/manage schedules
velero schedule get
velero schedule pause <schedule-name>
velero schedule unpause <schedule-name>
velero schedule delete <schedule-name>

# Check backup storage location health
velero backup-location get
```

---

## Troubleshooting

**Backup stuck in `InProgress`:**
```bash
kubectl get datauploads -n velero
kubectl describe dataupload <name> -n velero
kubectl logs -n velero -l component=velero --tail=100
```

**`NotImplemented` errors from S3:**
Add `checksumAlgorithm=""` to your backup-location config:
```bash
velero backup-location set default \
  --config region=us-east-1,s3ForcePathStyle=true,s3Url=http://<SEAWEEDFS_S3_ENDPOINT>:8333,checksumAlgorithm=""
```

**VolumeSnapshot not being created:**
Verify the VolumeSnapshotClass exists and is labeled:
```bash
kubectl get volumesnapshotclass -l velero.io/csi-volumesnapshot-class=true
```

**Restore PVC stuck in Pending:**
Ensure you're using Velero v1.14+ (CSI plugin built-in), which fixes annotation compatibility issues with older versions.

**Node agent pod failing:**
```bash
kubectl describe pod -n velero -l name=node-agent
kubectl logs -n velero -l name=node-agent --tail=50
```

---

## Full Disaster Recovery Walkthrough

If your node dies and you need to rebuild from scratch on a fresh Ubuntu 22.04 machine:

### 1. Rebuild the base cluster

Install Ubuntu 22.04 and set up your Kubernetes distribution (same as the original). Install the CNI (Calico + Tigera operator). Don't deploy any workloads yet.

### 2. (Optional) Restore etcd snapshot for in-place recovery

If the control plane is broken but the node is still there, restore the etcd snapshot:
```bash
# kubeadm example — stop API server first
sudo systemctl stop kubelet
sudo ETCDCTL_API=3 etcdctl snapshot restore /path/to/etcd-snapshot.db \
  --data-dir=/var/lib/etcd-restored
# Update /etc/kubernetes/manifests/etcd.yaml to point to /var/lib/etcd-restored
sudo systemctl start kubelet
```

For a **fresh node** rebuild, skip this — Velero handles the rest.

### 3. Install Longhorn

Install Longhorn as you did originally. It must be running before Velero can restore PVCs for dell-portal and dell-orchestrator.

### 4. Install Velero (pointed at the same S3 bucket)

Run the same `velero install` command from Step 6. Because the S3 bucket already contains your backups, Velero will auto-discover them within ~1 minute.

```bash
# Verify it found the old backups
velero backup get
```

### 5. Restore

```bash
# Restore from the latest daily backup
velero restore create full-restore \
  --from-backup <backup-name> \
  --wait

# Monitor progress (PVC data download for dell namespaces may take a while)
velero restore describe full-restore --details
kubectl get datadownloads -n velero
```

### 6. Verify your stack

```bash
# Check all namespaces came back
kubectl get namespaces
# Expect: default, dell-portal, dell-orchestrator, haproxy-controller, metallb-system

# Check MetalLB config was restored
kubectl get ipaddresspool -n metallb-system
kubectl get l2advertisement -n metallb-system

# Check HAProxy is routing
kubectl get pods -n haproxy-controller
kubectl get ingress --all-namespaces   # or your equivalent routing resources

# Check dell apps and their PVC data
kubectl get pods -n dell-portal
kubectl get pods -n dell-orchestrator
kubectl get pvc -n dell-portal
kubectl get pvc -n dell-orchestrator

# Verify LoadBalancer IPs were assigned
kubectl get svc --all-namespaces | grep LoadBalancer
```

### Recovery order summary

```
Fresh Ubuntu 22.04
  └─▶ Kubernetes + Calico (fresh install)
       └─▶ Longhorn (fresh install)
            └─▶ Velero (fresh install, same S3 bucket)
                 └─▶ velero restore (brings back everything else):
                      ├── metallb-system  (config + CRDs)
                      ├── haproxy-controller (config + routing rules)
                      ├── dell-portal (manifests + PVC data from S3)
                      ├── dell-orchestrator (manifests + PVC data from S3)
                      ├── default namespace resources
                      └── cluster-scoped resources (CRDs, RBAC, StorageClasses)
```

> **Tip:** Velero restore is idempotent — it skips resources that already exist. If something
> goes wrong partway through, you can safely re-run the restore.

---

## Air-Gapped / Local Registry Installation

If your RKE2 cluster cannot pull images from the public internet (or you simply prefer hosting images locally), you can mirror the required Velero container images to your own private registry. This section covers pulling, tagging, pushing, and installing Velero from that registry.

**Prerequisites:** Docker installed on a workstation that has internet access (used to pull and push images).

### Required Container Images

Velero v1.17.x requires three images:

| Image | Description |
|-------|-------------|
| `velero/velero:v1.17.1` | Velero server + node-agent |
| `velero/velero-plugin-for-aws:v1.13.0` | S3-compatible storage plugin (init container) |
| `velero/velero-restore-helper:v1.17.1` | Init container injected into pods during filesystem restore |

> **Note:** The restore-helper version should match the Velero server version. Adjust all version tags below if you're using a different release.

### Step 1: Pull Images (internet-connected machine)

```bash
VELERO_VERSION="v1.17.1"
AWS_PLUGIN_VERSION="v1.13.0"

docker pull velero/velero:${VELERO_VERSION}
docker pull velero/velero-plugin-for-aws:${AWS_PLUGIN_VERSION}
docker pull velero/velero-restore-helper:${VELERO_VERSION}
```

Verify:
```bash
docker images | grep velero
```

### Step 2: Tag and Push to Your Private Registry

Replace the placeholder variables with your registry details:

```bash
# ── Registry connection details ──────────────────────────────────
REGISTRY_URL="registry.example.com"   # hostname or IP
REGISTRY_PORT="5000"                   # registry port
REGISTRY_USER="your-username"
REGISTRY_PASS="your-password"

VELERO_VERSION="v1.17.1"
AWS_PLUGIN_VERSION="v1.13.0"
DEST="${REGISTRY_URL}:${REGISTRY_PORT}"

# ── Login ─────────────────────────────────────────────────────────
docker login "${DEST}" -u "${REGISTRY_USER}" -p "${REGISTRY_PASS}"

# ── Tag ───────────────────────────────────────────────────────────
docker tag velero/velero:${VELERO_VERSION}                  ${DEST}/velero/velero:${VELERO_VERSION}
docker tag velero/velero-plugin-for-aws:${AWS_PLUGIN_VERSION} ${DEST}/velero/velero-plugin-for-aws:${AWS_PLUGIN_VERSION}
docker tag velero/velero-restore-helper:${VELERO_VERSION}   ${DEST}/velero/velero-restore-helper:${VELERO_VERSION}

# ── Push ──────────────────────────────────────────────────────────
docker push ${DEST}/velero/velero:${VELERO_VERSION}
docker push ${DEST}/velero/velero-plugin-for-aws:${AWS_PLUGIN_VERSION}
docker push ${DEST}/velero/velero-restore-helper:${VELERO_VERSION}
```

> **Tip — offline transfer:** If the workstation can't reach the registry directly, you can save the images to a tarball, transfer it, then load and push from a machine that can reach the registry:
> ```bash
> # Save on internet-connected machine
> docker save -o velero-images.tar \
>   velero/velero:${VELERO_VERSION} \
>   velero/velero-plugin-for-aws:${AWS_PLUGIN_VERSION} \
>   velero/velero-restore-helper:${VELERO_VERSION}
>
> # Load on registry-connected machine
> docker load -i velero-images.tar
> # Then tag and push as above
> ```

### Step 3: Configure RKE2 to Use Your Private Registry

RKE2 uses `/etc/rancher/rke2/registries.yaml` to configure containerd's registry mirrors and authentication. Create or edit this file on **every node** in your cluster (server and agent nodes):

```bash
sudo mkdir -p /etc/rancher/rke2

sudo tee /etc/rancher/rke2/registries.yaml > /dev/null <<'EOF'
mirrors:
  docker.io:
    endpoint:
      - "https://<REGISTRY_URL>:<REGISTRY_PORT>"

configs:
  "<REGISTRY_URL>:<REGISTRY_PORT>":
    auth:
      username: <REGISTRY_USER>
      password: <REGISTRY_PASS>
    tls:
      insecure_skip_verify: false    # set to true for self-signed certs if not providing ca_file
      # ca_file: /etc/rancher/rke2/registry-ca.crt   # uncomment if using self-signed TLS
EOF
```

Replace the `<PLACEHOLDER>` values with your actual registry details. If your registry does **not** use TLS, change `https://` to `http://` in the endpoint and you can remove the `tls` block.

**Restart RKE2** for the changes to take effect:
```bash
# On server nodes
sudo systemctl restart rke2-server

# On agent nodes (if any)
sudo systemctl restart rke2-agent
```

> **How this works:** The `mirrors` section tells containerd that when it needs to pull an image from `docker.io` (which includes all `velero/*` images), it should try your private registry first. The `configs` section provides the credentials and TLS settings for your registry endpoint.

### Step 4: Install Velero Using Private Registry Images

Use the `--image` flag to point the Velero server/node-agent image at your registry, and the `--plugins` flag for the AWS plugin image:

```bash
DEST="<REGISTRY_URL>:<REGISTRY_PORT>"

velero install \
  --image ${DEST}/velero/velero:v1.17.1 \
  --plugins ${DEST}/velero/velero-plugin-for-aws:v1.13.0 \
  --provider aws \
  --bucket velero-backups \
  --backup-location-config \
    region=us-east-1,s3ForcePathStyle=true,s3Url=https://<SEAWEEDFS_S3_ENDPOINT>:8333,checksumAlgorithm="" \
  --secret-file /tmp/credentials-velero \
  --features=EnableCSI \
  --use-node-agent \
  --use-volume-snapshots=true \
  --cacert /path/to/seaweedfs-ca.crt \
  --wait
```

The `--image` and `--plugins` flags override the default Docker Hub references. All other flags remain the same as the standard installation (Step 6).

### Step 5: Configure the Restore Helper Image

During a restore that involves filesystem backup data, Velero injects an init container called the **restore helper** into each restored pod. By default it pulls `velero/velero-restore-helper` from Docker Hub. To point it at your private registry, create a ConfigMap in the `velero` namespace:

```bash
DEST="<REGISTRY_URL>:<REGISTRY_PORT>"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: fs-restore-action-config
  namespace: velero
  labels:
    velero.io/plugin-config: ""
    velero.io/change-image-name: RestoreItemAction
data:
  velero/velero-restore-helper: "${DEST}/velero/velero-restore-helper"
EOF
```

> **What this does:** The `velero.io/change-image-name` label tells Velero to rewrite the restore-helper image reference during restores. Any pod that would normally pull `velero/velero-restore-helper:v1.17.1` will instead pull from your private registry.

### Step 6: Create an ImagePullSecret (alternative to registries.yaml)

If you prefer Kubernetes-native pull secrets instead of (or in addition to) RKE2's `registries.yaml`, you can create a secret and patch the Velero service account:

```bash
# Create the pull secret
kubectl create secret docker-registry registry-creds \
  --namespace velero \
  --docker-server=<REGISTRY_URL>:<REGISTRY_PORT> \
  --docker-username=<REGISTRY_USER> \
  --docker-password=<REGISTRY_PASS>

# Patch the velero service account to use it
kubectl patch serviceaccount velero -n velero \
  -p '{"imagePullSecrets": [{"name": "registry-creds"}]}'

# Patch the node-agent service account
kubectl patch serviceaccount node-agent -n velero \
  -p '{"imagePullSecrets": [{"name": "registry-creds"}]}'

# Restart to pick up the change
kubectl rollout restart deployment/velero -n velero
kubectl rollout restart daemonset/node-agent -n velero
```

> **When to use this:** The `registries.yaml` approach (Step 3) is simpler for RKE2 clusters — it's cluster-wide and transparent. The ImagePullSecret approach is useful if you can't modify `registries.yaml` or if other workloads in the cluster should not access the registry.

### Verify Air-Gapped Installation

```bash
# All pods should be Running with no ImagePullBackOff errors
kubectl get pods -n velero

# Confirm images are from your registry
kubectl get pods -n velero -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  container: {.image}{"\n"}{end}{range .spec.initContainers[*]}  init: {.image}{"\n"}{end}{end}'

# Backup location should show Available
velero backup-location get
```

---

## Security Notes

- Delete the credentials file after installation: `rm /tmp/credentials-velero`
- The credentials are stored as a Kubernetes Secret in the `velero` namespace (`velero` or `cloud-credentials`)
- Consider creating a dedicated SeaweedFS user/key with access only to the `velero-backups` bucket
- Velero encrypts backup repository data by default (Kopia encryption). You can set a custom password via the `velero-repo-credentials` secret before the first backup
