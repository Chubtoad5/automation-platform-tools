#!/bin/bash
# A3, on the storage host: ap-tools install swfs, with a velero bucket and monitoring. Hands its S3 keys to the cluster role.
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
systemctl disable --now cockpit.socket >/dev/null 2>&1 || true
export HOST_FQDN=files.ci.test BASE_DOMAIN=ci.test DEBUG=0 EXTRA_BUCKETS=velero ENABLE_MONITORING=true SWFS_HARBOR_PASS=Test-Pass-1
./ap-tools install swfs > "$W/o" 2>&1 && ok "ap-tools install swfs" || { bad "ap-tools install swfs"; show; }
creds=/opt/seaweedfs/monitoring-credentials.env
if [ -r "$creds" ]; then
  # shellcheck disable=SC1090
  . "$creds"
  echo "CI-EXPORT A3_S3_ACCESS_KEY=$MONITORING_S3_ACCESS_KEY"
  echo "CI-EXPORT A3_S3_SECRET_KEY=$MONITORING_S3_SECRET_KEY"
  ok "hand the S3 keys on"
else
  bad "no $creds"
fi
s3pair="${MONITORING_S3_ACCESS_KEY:-}:${MONITORING_S3_SECRET_KEY:-}"
code=$(curl -sk -m 10 --aws-sigv4 aws:amz:us-east-1:s3 --user "$s3pair" -o "$W/b" -w '%{http_code}' "https://$IP:8333/")
[ "$code" = 200 ] && grep -q '<Name>velero</Name>' "$W/b" && ok "S3 answers, and has the velero bucket" || bad "S3 answered $code, buckets: $(grep -o '<Name>[^<]*' "$W/b" | tr '\n' ' ')"
up() { [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:9090/-/ready")" = 200 ] && [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:3100/ready")" = 200 ]; }
within 120 up && ok "Prometheus and Loki are ready for the cluster" || bad "Prometheus or Loki isn't ready"
echo "=== exit $fail"; exit $fail
