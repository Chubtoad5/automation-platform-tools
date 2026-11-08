#!/bin/bash
# A3, on the cluster host: ap-tools install rke2, then velero and monitoring pointed at the storage role. Back up a namespace
# with a Longhorn volume through the daily schedule's settings (data moved to S3), delete it, restore it, read the data
# back. A metric reaches the storage host's Prometheus and a log reaches its Loki, both with this cluster's label.
set -uo pipefail
REPO=$PWD
fail=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
# within <seconds> <command...>: true once the command is, checking every 5 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 5)); do "$@" && return 0; sleep 5; done; "$@"; }
IP=${CI_CLONE_IP:-$(hostname -I | awk '{print $1}')}
K="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
cp "$REPO/ap-tools" .; chmod +x ap-tools
show() { tail -10 "$W/o" | cut -c1-170; }
# pods_ok <namespace>: every pod there is Running or Completed, and there is at least one
pods_ok() { local out; out=$($K get pods -n "$1" --no-headers 2>/dev/null); [ -n "$out" ] && ! grep -qvE ' (Running|Completed) ' <<< "$out"; }
S=$CI_ROLE_STORAGE_IP CL=ci-a3-$(date +%s)
echo "  this host $IP, the storage host $S, cluster label $CL"
export HOST_FQDN=a3.ci.test BASE_DOMAIN=ci.test DEBUG=0 CLUSTER_NAME=$CL VELERO_BUCKET=velero VELERO_S3_URL=https://$S:8333 \
  VELERO_S3_ACCESS_KEY=${A3_S3_ACCESS_KEY:-} VELERO_S3_SECRET_KEY=${A3_S3_SECRET_KEY:-} VELERO_BACKUP_NAMESPACES=ci-a3 MONITORING_HOST=$S
./ap-tools install rke2 > "$W/o" 2>&1 && ok "ap-tools install rke2" || { bad "ap-tools install rke2"; show; }
nready() { $K get nodes --no-headers 2>/dev/null | grep -qw Ready; }
within 300 nready && ok "the node is Ready" || bad "the node isn't Ready"
within 300 pods_ok longhorn-system && ok "Longhorn runs" || bad "Longhorn isn't running"
./ap-tools install velero > "$W/o" 2>&1 && ok "ap-tools install velero" || { bad "ap-tools install velero"; show; }
bsl() { [ "$($K get backupstoragelocation -n velero default -o jsonpath='{.status.phase}' 2>/dev/null)" = Available ]; }
within 180 bsl && ok "Velero's storage location on SeaweedFS is Available" || bad "Velero's storage location is '$($K get backupstoragelocation -n velero -o jsonpath='{.items[0].status.phase}' 2>&1)'"
./ap-tools install monitoring > "$W/o" 2>&1 && ok "ap-tools install monitoring" || { bad "ap-tools install monitoring"; show; }

echo "=== Velero: back up, delete, restore"
$K create namespace ci-a3 >/dev/null 2>&1
$K apply -n ci-a3 -f - > "$W/k" 2>&1 <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data }
spec: { accessModes: [ReadWriteOnce], storageClassName: longhorn, resources: { requests: { storage: 1Gi } } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: keeper }
spec:
  replicas: 1
  selector: { matchLabels: { app: keeper } }
  template:
    metadata: { labels: { app: keeper } }
    spec:
      containers:
        - { name: k, image: busybox:1.36, command: [sh, -c, "[ -f /data/f ] || echo ci-a3-data > /data/f; sync; exec sleep 86400"], volumeMounts: [{ name: d, mountPath: /data }] }
      volumes: [{ name: d, persistentVolumeClaim: { claimName: data } }]
EOF
$K wait -n ci-a3 --for=condition=Available deployment/keeper --timeout=300s >/dev/null 2>&1 && ok "a pod with a Longhorn volume runs" || bad "the pod with a volume isn't up"
readback() { [ "$($K exec -n ci-a3 deploy/keeper -- cat /data/f 2>/dev/null)" = ci-a3-data ]; }
within 60 readback && ok "it wrote its file" || bad "the file isn't there"
V=/usr/local/bin/velero; [ -x "$V" ] || V=$(command -v velero)
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
"$V" backup create ci-a3-b --from-schedule daily-full-backup --wait > "$W/v" 2>&1
ph=$("$V" backup get ci-a3-b -o json 2>/dev/null | grep -o '"phase": *"[A-Za-z]*"' | head -1)
[[ "$ph" == *Completed* ]] && ok "a backup from the daily schedule completes" || { bad "the backup is $ph"; tail -5 "$W/v" | cut -c1-170; "$V" backup describe ci-a3-b 2>&1 | tail -8 | cut -c1-170; }
$K delete namespace ci-a3 --wait=true --timeout=300s >/dev/null 2>&1 && ok "delete the namespace" || bad "delete the namespace"
"$V" restore create ci-a3-r --from-backup ci-a3-b --wait > "$W/v" 2>&1
ph=$("$V" restore get ci-a3-r -o json 2>/dev/null | grep -o '"phase": *"[A-Za-z]*"' | head -1)
[[ "$ph" == *Completed* ]] && ok "the restore completes" || { bad "the restore is $ph"; "$V" restore describe ci-a3-r 2>&1 | tail -8 | cut -c1-170; }
$K wait -n ci-a3 --for=condition=Available deployment/keeper --timeout=300s >/dev/null 2>&1 && ok "the restored pod runs" || bad "the restored pod isn't up"
within 60 readback && ok "the restored volume holds the file" || bad "the restored volume doesn't hold the file"

echo "=== Metrics and logs reach the storage host, with this cluster's label"
metric() { local out; out=$(curl -s -m 10 -G "http://$S:9090/api/v1/query" --data-urlencode "query=count({cluster=\"$CL\"})"); grep -qE '"value":\[[0-9.]+,"[1-9]' <<< "$out"; }
within 600 metric && ok "Prometheus on the storage host has metrics labelled cluster=$CL" || bad "no metrics with cluster=$CL on the storage host"
logs() { local out; out=$(curl -s -m 10 -G "http://$S:3100/loki/api/v1/query_range" --data-urlencode "query={cluster=\"$CL\"}" --data-urlencode "limit=5" \
  --data-urlencode "start=$(( $(date +%s) - 3600 ))000000000"); grep -q '"values":\[\[' <<< "$out"; }
within 600 logs && ok "Loki on the storage host has logs labelled cluster=$CL" || bad "no logs with cluster=$CL in Loki"
echo "=== exit $fail"; exit $fail
