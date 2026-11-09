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
# As the README says: ap-offline.tar.gz beside ap-tools, unpacked there. The archive itself is what turns air-gapped mode on.
cp "$CI_HANDOFF/ap-offline.tar.gz" . && tar -xzf ap-offline.tar.gz && ok "copy the bundle beside ap-tools and unpack it" \
  || { bad "copy and unpack the bundle"; echo "=== exit 1"; exit 1; }
export HOST_FQDN=a1.ci.test BASE_DOMAIN=ci.test DEBUG=0
# SUSE has no rke2-selinux policy, so on an enforcing host rke2 refuses unless told to fall back to permissive. That
# opt-in reaches rke2_installer.sh through the environment, as rke2's own tests set it.
. /etc/os-release
if [[ "$ID" =~ ^(sles|opensuse-leap)$ && "$(getenforce 2>/dev/null)" == Enforcing ]]; then export RKE2_SELINUX_FALLBACK=permissive; fi
# On a failed install, what it takes to tell why a pod isn't ready: its last log lines and its namespace's latest events
why_not_ready() {
  local ns p
  # Not ready: anything but Completed, and anything Running with fewer containers ready than it has
  $K get pods -A --no-headers 2>/dev/null | awk '{ split($3, r, "/") } $4 != "Completed" && ($4 != "Running" || r[1] != r[2]) { print $1, $2 }' |
    head -4 | while read -r ns p; do
    echo "  --- $ns/$p: last log lines"; $K logs -n "$ns" "$p" --tail=8 2>&1 | cut -c1-170 | sed 's/^/    /'
    echo "  --- $ns/$p: previous container"; $K logs -n "$ns" "$p" --previous --tail=5 2>&1 | cut -c1-170 | sed 's/^/    /'
  done
  echo "  --- kube-system events"; $K get events -n kube-system --sort-by=.lastTimestamp 2>/dev/null | tail -6 | cut -c1-170 | sed 's/^/    /'
  echo "  --- resolv.conf: $(grep -v '^#' /etc/resolv.conf | tr '\n' ' ')"
}
./ap-tools install rke2 > "$W/o" 2>&1 && ok "ap-tools install rke2 with no route out" || { bad "ap-tools install rke2 with no route out"; tail -10 "$W/o" | cut -c1-170; why_not_ready; echo "  (the checks after it would only fail too)"; echo "=== exit 1"; exit 1; }
nready() { $K get nodes --no-headers 2>/dev/null | grep -qw Ready; }
within 300 nready && ok "the node is Ready" || bad "the node isn't Ready"
grep -q "AIR_GAPPED_MODE: 1" "$W/o" && ok "it installs in air-gapped mode" || bad "it didn't install in air-gapped mode"
for ns in kube-system haproxy-controller metallb-system longhorn-system; do
  within 300 pods_ok "$ns" && ok "$ns: every pod runs" || bad "$ns: $($K get pods -n "$ns" --no-headers 2>&1 | grep -vE ' (Running|Completed) ' | head -3)"
done
AP_ASSUME_YES=true ./ap-tools uninstall rke2 > "$W/o" 2>&1 && ok "ap-tools uninstall rke2" || { bad "ap-tools uninstall rke2"; tail -6 "$W/o" | cut -c1-170; }
echo "=== exit $fail"; exit $fail
