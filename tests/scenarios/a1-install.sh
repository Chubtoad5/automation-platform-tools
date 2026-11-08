#!/bin/bash
# A1, on a host with no route out: install rke2 with HAProxy, MetalLB and Longhorn from the bundle the build role made.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
# within <seconds> <command...>: true once the command is, checking every 5 seconds
within() { local t=$1 i; shift; for ((i = 0; i < t; i += 5)); do "$@" && return 0; sleep 5; done; "$@"; }
K="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
pods_ok() { local out; out=$($K get pods -n "$1" --no-headers 2>/dev/null); [ -n "$out" ] && ! grep -qvE ' (Running|Completed) ' <<< "$out"; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
cp "$REPO/ap-tools" .; chmod +x ap-tools
tar -xzf "$CI_HANDOFF/ap-offline.tar.gz" && ok "unpack the bundle" || { bad "unpack the bundle"; echo "=== exit 1"; exit 1; }
export HOST_FQDN=a1.ci.test BASE_DOMAIN=ci.test DEBUG=0
./ap-tools install rke2 > "$W/o" 2>&1 && ok "ap-tools install rke2 with no route out" || { bad "ap-tools install rke2 with no route out"; tail -10 "$W/o" | cut -c1-170; }
nready() { $K get nodes --no-headers 2>/dev/null | grep -qw Ready; }
within 300 nready && ok "the node is Ready" || bad "the node isn't Ready"
for ns in kube-system haproxy-controller metallb-system longhorn-system; do
  within 300 pods_ok "$ns" && ok "$ns: every pod runs" || bad "$ns: $($K get pods -n "$ns" --no-headers 2>&1 | grep -vE ' (Running|Completed) ' | head -3)"
done
AP_ASSUME_YES=true ./ap-tools uninstall rke2 > "$W/o" 2>&1 && ok "ap-tools uninstall rke2" || { bad "ap-tools uninstall rke2"; tail -6 "$W/o" | cut -c1-170; }
echo "=== exit $fail"; exit $fail
