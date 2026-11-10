#!/bin/bash
# A5: "ap-tools install rke2" from the last release (its source archive from GitHub), a workload that writes to a
# Longhorn volume, then the commit under test's "install rke2" over it. It reconciles, and the stack, the workload and its
# data are still there. The sub-tools come from each version's own pins, or from the commit under test (CI sets *_REF).
set -uo pipefail
REPO=$PWD
fail=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 5)); do "$@" && return 0; sleep 5; done; "$@"; }
K="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
R=automation-platform-tools
old=$(curl -sI -m 20 "https://github.com/Chubtoad5/$R/releases/latest" | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/tag/##p')
[[ "$old" =~ ^v[0-9]+(\.[0-9]+)+$ ]] && ok "the last release is $old" || { bad "couldn't find the last release: '$old'"; echo "=== exit 1"; exit 1; }
mkdir old new
curl -sfL -m 180 "https://github.com/Chubtoad5/$R/archive/refs/tags/$old.tar.gz" | tar -xz -C old --strip-components=1 && [ -f old/ap-tools ] \
  && ok "download $old" || { bad "download $old"; echo "=== exit 1"; exit 1; }
cp "$REPO/ap-tools" new/; chmod +x old/ap-tools new/ap-tools
pods_ok() { local out; out=$($K get pods -n "$1" --no-headers 2>/dev/null); [ -n "$out" ] && ! grep -qvE ' (Running|Completed) ' <<< "$out"; }
nready() { $K get nodes --no-headers 2>/dev/null | grep -qw Ready; }
data() { $K exec -n a5 deploy/keeper -- cat /data/f 2>/dev/null; }
wrote() { [ "$(data)" = a5-before-upgrade ]; }
stack_ok() {
  local ns
  for ns in haproxy-controller metallb-system longhorn-system; do
    within 300 pods_ok "$ns" && ok "$1: $ns, every pod runs" || bad "$1: $ns: $($K get pods -n "$ns" --no-headers 2>&1 | grep -vE ' (Running|Completed) ' | head -3 | tr '\n' ';')"
  done
}
export HOST_FQDN=a5.ci.test BASE_DOMAIN=ci.test DEBUG=0

(cd old && ./ap-tools install rke2) > o1 2>&1 && ok "$old: ap-tools install rke2" || { bad "$old: ap-tools install rke2"; tail -10 o1 | cut -c1-170; echo "=== exit 1"; exit 1; }
within 300 nready && ok "$old: the node is Ready" || bad "$old: the node isn't Ready"
stack_ok "$old"
$K apply -f - > /dev/null <<'YAML' && ok "a workload with a Longhorn volume" || bad "couldn't create the workload"
apiVersion: v1
kind: Namespace
metadata: { name: a5 }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data, namespace: a5 }
spec: { accessModes: [ReadWriteOnce], storageClassName: longhorn, resources: { requests: { storage: 1Gi } } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: keeper, namespace: a5 }
spec:
  replicas: 1
  selector: { matchLabels: { app: keeper } }
  template:
    metadata: { labels: { app: keeper } }
    spec:
      containers:
        - name: c
          image: busybox:1.36
          command: [sh, -c, '[ -f /data/f ] || echo a5-before-upgrade > /data/f; exec sleep 1000000']
          volumeMounts: [{ name: d, mountPath: /data }]
      volumes: [{ name: d, persistentVolumeClaim: { claimName: data } }]
YAML
within 300 wrote && ok "it wrote to its Longhorn volume" || bad "the workload didn't write: $($K get pods -n a5 --no-headers 2>&1 | head -2)"

(cd new && ./ap-tools install rke2) > o2 2>&1 && ok "the commit under test's ap-tools install rke2 over $old" || { bad "the commit under test's ap-tools install rke2 over $old"; tail -12 o2 | cut -c1-170; }
within 300 nready && ok "the node is Ready after the upgrade" || bad "the node isn't Ready after the upgrade"
stack_ok "after the upgrade"
within 180 wrote && ok "the workload and its Longhorn data survived" || bad "the workload's data is gone: '$(data)'"
[ "$($K get pods -A --no-headers 2>/dev/null | grep -c 'ingress-nginx')" = 0 ] && ok "still no nginx ingress pod" || bad "an nginx ingress pod appeared"
(cd new && AP_ASSUME_YES=true ./ap-tools uninstall rke2) > o3 2>&1 && ok "ap-tools uninstall rke2" || { bad "ap-tools uninstall rke2"; tail -6 o3 | cut -c1-170; }
systemctl is-active --quiet rke2-server && bad "rke2-server is still running" || ok "rke2-server is gone"
echo "=== exit $fail"; exit $fail
