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
#
# Examples:
#   bash preflight.sh --dns portal.myhost.mydomain.lab,orchestrator.myhost.mydomain.lab
#   bash preflight.sh --dns "$(echo portal.x,orchestrator.x,mtls-orchestrator.x,mtls-recovery-orchestrator.x)" --multi-node

set -u

MIN_CPU=16
MIN_RAM_GB=34          # 34, not 32: RKE2 reserves ~2GB; the bundle pre-check measures allocatable.
MIN_DISK_GB=500
DISK_PATH="/"
DNS_NAMES=""
MULTI_NODE=0
SKIP_DNS=0
SKIP_RES=0

fail=0
pass_msg() { printf '  [PASS] %s\n' "$1"; }
fail_msg() { printf '  [FAIL] %s\n' "$1"; fail=1; }
warn_msg() { printf '  [WARN] %s\n' "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dns)            DNS_NAMES="$2"; shift 2 ;;
    --multi-node)     MULTI_NODE=1; shift ;;
    --cpu)            MIN_CPU="$2"; shift 2 ;;
    --ram-gb)         MIN_RAM_GB="$2"; shift 2 ;;
    --disk-gb)        MIN_DISK_GB="$2"; shift 2 ;;
    --disk-path)      DISK_PATH="$2"; shift 2 ;;
    --skip-dns)       SKIP_DNS=1; shift ;;
    --skip-resources) SKIP_RES=1; shift ;;
    -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

echo "== ap-tools / Dell AP preflight =="
[ "$MULTI_NODE" -eq 1 ] && echo "(multi-node mode: run this on every node)"

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
    if [ "$mem_gb" -ge "$MIN_RAM_GB" ]; then pass_msg "RAM: ${mem_gb} GB (>= ${MIN_RAM_GB})"
    else fail_msg "RAM: ${mem_gb} GB (need >= ${MIN_RAM_GB}; use 34 not 32)"; fi
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
