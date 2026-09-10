#!/usr/bin/env bash
# preflight.sh — environment-agnostic readiness check for an ap-tools / Dell AP install.
#
# Run this ON the target host (it inspects local CPU/RAM/disk and OS), optionally resolving the
# DNS names the install will need. It is READ-ONLY: it changes nothing and contains no credentials.
# Exits 0 only if every enabled check passes; non-zero otherwise.
#
# Usage:
#   bash preflight.sh [--dns name1,name2,...] [--multi-node]
#                     [--cpu N] [--ram-gb N] [--disk-gb N] [--disk-path PATH]
#                     [--skip-dns] [--skip-resources]
#                     [--ddpc [--dap-version X.Y.Z.W] [--namespace NS] [--portal-namespace NS]]
#
# --ddpc: readiness for the Dell Distributed Private Cloud add-on (`install ddpc-bundle`). Run it ON a
#   DAP control-plane node (needs kubectl + helm): checks the DAP orchestrator/portal helm releases are
#   deployed at the expected version, no platform pod is unhealthy, no DDPC release is stuck, and reports
#   the unrequested CPU/memory headroom. Host CPU/RAM/disk gates are skipped in this mode (DAP already
#   passed them); pass --dns orchestrator.<domain> to confirm the DAPO_HOST name resolves.
#
# Examples:
#   bash preflight.sh --dns portal.myhost.mydomain.lab,orchestrator.myhost.mydomain.lab
#   bash preflight.sh --dns "$(echo portal.x,orchestrator.x,mtls-orchestrator.x,mtls-recovery-orchestrator.x)" --multi-node
#   bash preflight.sh --ddpc --dns orchestrator.myhost.mydomain.lab

set -u

MIN_CPU=18
MIN_RAM_GB=36          # single-node floor. The bundle pre-check measures ALLOCATABLE memory and RKE2 + the OS
                       # reserve ~2 GB, so provision 36 to leave ~34 allocatable.
MIN_RAM_GB_MULTI=20    # per-node floor for a 3-node cluster (16 GB/node wedges the Orchestrator install).
RAM_TOLERANCE_GB=2     # a VM "allocated" N GiB presents MemTotal a bit under N (firmware/kernel reserve);
                       # accept mem >= floor - tolerance so a real 20 GB node (shows ~19) passes while 16 still fails.
# 850 GB, raised from 500: DAP 2.1.1.0's own pre_install_check enforces REQUIRED_DISK_SPACE=850Gi against each
# node's ALLOCATABLE ephemeral-storage. Allocatable is always below the raw filesystem size, so a host with
# exactly 850 GB free can still fail Dell's gate - 1 TB is the safe provisioning target. A 500 GB host used to
# pass this script and then fail Dell's check partway through the install.
MIN_DISK_GB=850
DISK_PATH="/"
DNS_NAMES=""
MULTI_NODE=0
RAM_EXPLICIT=0
SKIP_DNS=0
SKIP_RES=0
DDPC=0
DDPC_DAP_VERSION="2.1.1.0"     # DAP orchestrator app version the DDPC 4.3.0.0 bundle pairs with (exact match)
DDPC_NS="dell-orchestrator"
DDPC_PORTAL_NS="dell-portal"
DDPC_MIN_CPU_HEADROOM=2        # unrequested cores; mirrors ap-tools DDPC_REQUIRED_CPU_HEADROOM
DDPC_MIN_MEM_HEADROOM_GB=4     # unrequested GB;   mirrors ap-tools DDPC_REQUIRED_MEM_HEADROOM_GB

fail=0
pass_msg() { printf '  [PASS] %s\n' "$1"; }
fail_msg() { printf '  [FAIL] %s\n' "$1"; fail=1; }
warn_msg() { printf '  [WARN] %s\n' "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dns)            DNS_NAMES="$2"; shift 2 ;;
    --multi-node)     MULTI_NODE=1; shift ;;
    --cpu)            MIN_CPU="$2"; shift 2 ;;
    --ram-gb)         MIN_RAM_GB="$2"; RAM_EXPLICIT=1; shift 2 ;;
    --disk-gb)        MIN_DISK_GB="$2"; shift 2 ;;
    --disk-path)      DISK_PATH="$2"; shift 2 ;;
    --skip-dns)       SKIP_DNS=1; shift ;;
    --skip-resources) SKIP_RES=1; shift ;;
    --ddpc)           DDPC=1; SKIP_RES=1; shift ;;
    --dap-version)    DDPC_DAP_VERSION="$2"; shift 2 ;;
    --namespace)      DDPC_NS="$2"; shift 2 ;;
    --portal-namespace) DDPC_PORTAL_NS="$2"; shift 2 ;;
    -h|--help)        sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "== ap-tools / Dell AP preflight =="
# Multi-node uses a lower per-node RAM floor (20 GB) unless the caller set --ram-gb explicitly.
if [ "$MULTI_NODE" -eq 1 ]; then
  echo "(multi-node mode: run this on every node)"
  [ "$RAM_EXPLICIT" -eq 0 ] && MIN_RAM_GB="$MIN_RAM_GB_MULTI"
fi

# --- OS support ---------------------------------------------------------------
echo "Operating system:"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  case "${ID:-unknown}" in
    ubuntu|debian|rhel|centos|rocky|almalinux|fedora|sles|opensuse-leap)
      pass_msg "supported OS: ${ID} ${VERSION_ID:-}" ;;
    *)
      fail_msg "unsupported OS ID '${ID:-unknown}' (need ubuntu/debian/rhel/centos/rocky/almalinux/fedora/sles/opensuse-leap)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) pass_msg "architecture: $(uname -m)" ;;
    *) fail_msg "architecture $(uname -m) not supported (need x86_64)" ;;
  esac
else
  fail_msg "/etc/os-release not readable — cannot confirm OS"
fi

# --- Resources ----------------------------------------------------------------
if [ "$SKIP_RES" -eq 0 ]; then
  echo "Resources:"
  cores=$(nproc 2>/dev/null || echo 0)
  if [ "$cores" -ge "$MIN_CPU" ]; then pass_msg "CPU: ${cores} vCPU (>= ${MIN_CPU})"
  else fail_msg "CPU: ${cores} vCPU (need >= ${MIN_CPU})"; fi

  if [ -r /proc/meminfo ]; then
    mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    mem_gb=$(( mem_kb / 1024 / 1024 ))
    ram_floor=$(( MIN_RAM_GB - RAM_TOLERANCE_GB ))
    # MemTotal is always a bit under the VM's allocated RAM (firmware/kernel reserve), so a host
    # provisioned with exactly MIN_RAM_GB reports slightly less. Accept down to the tolerance floor.
    if [ "$mem_gb" -ge "$ram_floor" ]; then pass_msg "RAM: ${mem_gb} GB (target ${MIN_RAM_GB}, tolerance ${RAM_TOLERANCE_GB})"
    else fail_msg "RAM: ${mem_gb} GB (need ~${MIN_RAM_GB}; a ${MIN_RAM_GB} GB VM reports ~$(( MIN_RAM_GB - 1 )); this is below the ${ram_floor} GB floor)"; fi
  else
    warn_msg "cannot read /proc/meminfo — RAM not checked"
  fi

  disk_gb=$(df -BG --output=avail "$DISK_PATH" 2>/dev/null | awk 'NR==2{gsub("G","",$1); print $1}')
  if [ -n "${disk_gb:-}" ]; then
    if [ "$disk_gb" -ge "$MIN_DISK_GB" ]; then pass_msg "Disk free on ${DISK_PATH}: ${disk_gb} GB (>= ${MIN_DISK_GB})"
    else fail_msg "Disk free on ${DISK_PATH}: ${disk_gb} GB (need >= ${MIN_DISK_GB})"; fi
  else
    warn_msg "could not measure free disk on ${DISK_PATH}"
  fi
fi

# --- DDPC add-on readiness (in-cluster, read-only) ---------------------------
if [ "$DDPC" -eq 1 ]; then
  echo "DDPC add-on readiness (namespace ${DDPC_NS}, expects DAP ${DDPC_DAP_VERSION}):"
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
  export PATH="$PATH:/var/lib/rancher/rke2/bin:/usr/local/bin"
  if ! command -v kubectl >/dev/null 2>&1 || ! kubectl get nodes >/dev/null 2>&1; then
    fail_msg "kubectl cannot reach the cluster (run this on a DAP control-plane node as root)"
  else
    not_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1}' | tr '\n' ' ')
    if [ -n "$not_ready" ]; then fail_msg "node(s) not Ready: ${not_ready}"; else pass_msg "all nodes Ready"; fi
    if ! command -v helm >/dev/null 2>&1; then
      fail_msg "helm not found on PATH (ap-tools installs it to /usr/local/bin)"
    else
      dap_line=$(helm ls -n "$DDPC_NS" 2>/dev/null | awk '$NF != "" && $0 ~ /native-edge-orchestrator/ {print $8" "$NF}' | head -n 1)
      dap_status=${dap_line%% *}; dap_version=${dap_line##* }
      if [ -z "$dap_line" ]; then
        fail_msg "no native-edge-orchestrator helm release in ${DDPC_NS} - DAP is not installed"
      elif [ "$dap_status" != "deployed" ]; then
        fail_msg "DAP orchestrator release is '${dap_status}' (need deployed)"
      elif [ "$DDPC_DAP_VERSION" != "any" ] && [ "$dap_version" != "$DDPC_DAP_VERSION" ]; then
        fail_msg "DAP orchestrator version ${dap_version} != required ${DDPC_DAP_VERSION} (override with --dap-version if Dell supports the pairing)"
      else
        pass_msg "DAP orchestrator ${dap_version} deployed"
      fi
      portal_status=$(helm ls -n "$DDPC_PORTAL_NS" 2>/dev/null | awk '$0 ~ /dap-portal/ {print $8}' | head -n 1)
      if [ "$portal_status" = "deployed" ]; then pass_msg "DAP portal deployed"; else fail_msg "DAP portal release is '${portal_status:-missing}' (need deployed)"; fi
      ddpc_line=$(helm ls -n "$DDPC_NS" 2>/dev/null | awk '$1 == "dell-distributed-private-cloud" {print $8" "$NF}')
      if [ -n "$ddpc_line" ]; then
        case "${ddpc_line%% *}" in
          deployed) warn_msg "DDPC already deployed (${ddpc_line##* }); a re-run of the same bundle is a no-op, a newer bundle upgrades" ;;
          pending*) fail_msg "a DDPC helm operation is still pending (${ddpc_line}) - do not start another install" ;;
          *)        warn_msg "existing DDPC release is '${ddpc_line%% *}' - Dell's installer will retry it" ;;
        esac
      fi
    fi
    for ns in kube-system "$DDPC_PORTAL_NS" "$DDPC_NS"; do
      bad=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '$3 !~ /^(Running|Completed|Terminating)$/ {print $1"("$3")"}' | tr '\n' ' ')
      term=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '$3 == "Terminating" {print $1}' | tr '\n' ' ')
      if [ -n "$bad" ]; then fail_msg "unhealthy pod(s) in ${ns}: ${bad}"; else pass_msg "pods healthy in ${ns}"; fi
      [ -n "$term" ] && warn_msg "pod(s) stuck Terminating in ${ns} (not blocking; force-delete if they never clear): ${term}"
    done
    if command -v jq >/dev/null 2>&1; then
      alloc=$(kubectl get nodes -o json 2>/dev/null | jq '[.items[].status.allocatable | {cpu: (.cpu | if test("m$") then (sub("m$";"")|tonumber)/1000 else tonumber end), mem: (.memory | if test("Ki$") then (sub("Ki$";"")|tonumber)/1048576 elif test("Mi$") then (sub("Mi$";"")|tonumber)/1024 elif test("Gi$") then (sub("Gi$";"")|tonumber) else (tonumber/1073741824) end)}] | {cpu: (map(.cpu)|add), mem: (map(.mem)|add)}')
      req=$(kubectl get pods -A -o json 2>/dev/null | jq '[.items[] | select(.status.phase != "Succeeded" and .status.phase != "Failed") | (.spec.containers[]?.resources.requests // {})] | {cpu: ([.[] | .cpu // "0" | if test("m$") then (sub("m$";"")|tonumber)/1000 else tonumber end] | add // 0), mem: ([.[] | .memory // "0" | if test("Ki$") then (sub("Ki$";"")|tonumber)/1048576 elif test("Mi$") then (sub("Mi$";"")|tonumber)/1024 elif test("Gi$") then (sub("Gi$";"")|tonumber) elif test("M$") then (sub("M$";"")|tonumber)/1000 elif test("G$") then (sub("G$";"")|tonumber) else (tonumber/1073741824) end] | add // 0)}')
      cpu_free=$(jq -rn --argjson a "$alloc" --argjson r "$req" '($a.cpu - $r.cpu) * 100 | floor / 100')
      mem_free=$(jq -rn --argjson a "$alloc" --argjson r "$req" '($a.mem - $r.mem) * 10 | floor / 10')
      if [ "$(jq -rn --argjson v "$cpu_free" --argjson m "$DDPC_MIN_CPU_HEADROOM" '$v >= $m')" = "true" ]; then pass_msg "CPU headroom: ${cpu_free} cores unrequested (>= ${DDPC_MIN_CPU_HEADROOM})"; else fail_msg "CPU headroom: ${cpu_free} cores unrequested (need >= ${DDPC_MIN_CPU_HEADROOM})"; fi
      if [ "$(jq -rn --argjson v "$mem_free" --argjson m "$DDPC_MIN_MEM_HEADROOM_GB" '$v >= $m')" = "true" ]; then pass_msg "memory headroom: ${mem_free} GB unrequested (>= ${DDPC_MIN_MEM_HEADROOM_GB})"; else fail_msg "memory headroom: ${mem_free} GB unrequested (need >= ${DDPC_MIN_MEM_HEADROOM_GB})"; fi
    else
      warn_msg "jq not installed - headroom not computed (ap-tools installs jq before its own DDPC gate)"
    fi
  fi
fi

# --- DNS ----------------------------------------------------------------------
# Pick a resolver once. Distinguish "no tool available" from "name not found":
# getent/host/nslookup all return non-zero when a name does not resolve, which must FAIL.
if   command -v getent   >/dev/null 2>&1; then RESOLVER=getent
elif command -v host     >/dev/null 2>&1; then RESOLVER=host
elif command -v nslookup >/dev/null 2>&1; then RESOLVER=nslookup
elif command -v dig      >/dev/null 2>&1; then RESOLVER=dig
else RESOLVER=""; fi

resolve() {
  case "$RESOLVER" in
    getent)   getent ahosts "$1" >/dev/null 2>&1 ;;   # 0 = resolved, non-0 = not found
    host)     host "$1"          >/dev/null 2>&1 ;;
    nslookup) nslookup "$1"      >/dev/null 2>&1 ;;
    dig)      [ -n "$(dig +short "$1" 2>/dev/null)" ] ;;
  esac
}

if [ "$SKIP_DNS" -eq 0 ] && [ -n "$DNS_NAMES" ]; then
  echo "DNS resolution:"
  if [ -z "$RESOLVER" ]; then
    warn_msg "no resolver tool (getent/host/nslookup/dig) found — DNS not checked"
  else
    IFS=','; for name in $DNS_NAMES; do
      name="$(echo "$name" | tr -d '[:space:]')"
      [ -z "$name" ] && continue
      if resolve "$name"; then pass_msg "resolves: ${name}"
      else fail_msg "does NOT resolve: ${name}"; fi
    done
    unset IFS
  fi
elif [ "$SKIP_DNS" -eq 0 ]; then
  echo "DNS resolution:"
  warn_msg "no --dns names given — pass the portal/orchestrator/mtls FQDNs to validate them"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "PREFLIGHT: PASS"
  exit 0
else
  echo "PREFLIGHT: FAIL — resolve the [FAIL] items above before installing."
  exit 1
fi
