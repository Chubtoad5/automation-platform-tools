#!/bin/bash
# A2: ap-tools install rke2 push to a registry. HAProxy, MetalLB and Longhorn run, nginx ingress doesn't, a request goes
# through the HAProxy ingress, a Longhorn volume takes a write, and Harbor's audit log shows this job pulled from it.
# The sub-tools come from ap-tools' pins, or from the commit under test (CI sets its *_REF).
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
[ -n "${CI_SUPPORT_REGISTRY:-}" ] || { bad "no CI_SUPPORT_REGISTRY: A2 needs CI's support Harbor"; echo "=== exit 1"; exit 1; }
R=$CI_SUPPORT_REGISTRY RU=$CI_SUPPORT_REGISTRY_USER RP=$CI_SUPPORT_REGISTRY_PASSWORD
h() { curl -sk -m 20 -u "$RU:$RP" -H 'Content-Type: application/json' "$@"; }
# The projects ap-tools' push needs, from its own list
projects=$(bash -c 'eval "$(grep -E "^(REGISTRY_PROJECT_NAME|PROJECTS)=" "$1")"; echo "$PROJECTS"' _ "$REPO/ap-tools")
for p in $projects; do
  c=$(h -o /dev/null -w '%{http_code}' -X POST "https://$R/api/v2.0/projects" -d "{\"project_name\":\"$p\",\"metadata\":{\"public\":\"false\"}}")
  [[ "$c" == 201 || "$c" == 409 ]] || bad "create Harbor project $p: $c"
done
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
export HOST_FQDN=a2.ci.test BASE_DOMAIN=ci.test DEBUG=0
./ap-tools install rke2 push -registry "$R" "$RU" "$RP" > "$W/o" 2>&1 && ok "ap-tools install rke2 push" || { bad "ap-tools install rke2 push"; show; }
nready() { $K get nodes --no-headers 2>/dev/null | grep -qw Ready; }
within 300 nready && ok "the node is Ready" || bad "the node isn't Ready"
for ns in haproxy-controller metallb-system longhorn-system; do
  within 300 pods_ok "$ns" && ok "$ns: every pod runs" || bad "$ns: $($K get pods -n "$ns" --no-headers 2>&1 | grep -vE ' (Running|Completed) ' | head -3)"
done
n=$($K get pods -A --no-headers 2>/dev/null | grep -c 'ingress-nginx')
[ "$n" = 0 ] && ok "no nginx ingress pod" || bad "$n nginx ingress pods are running"
grep -q 'rke2-ingress-nginx' /etc/rancher/rke2/config.yaml && ok "config.yaml disables rke2-ingress-nginx" || bad "config.yaml doesn't disable rke2-ingress-nginx"
pool=$($K get ipaddresspools -A -o jsonpath='{.items[*].spec.addresses}' 2>/dev/null)
[[ " $pool " =~ [^0-9.]$IP(/32)?[^0-9./] ]] && ok "MetalLB's pool holds this node's address" || bad "MetalLB's pool is '$pool'"
lb() { lbip=$($K get svc -n haproxy-controller -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null); [ -n "$lbip" ]; }
within 120 lb
[ -n "$lbip" ] && ok "HAProxy's LoadBalancer has $lbip from MetalLB" || bad "HAProxy's LoadBalancer has no address"
class=$($K get ingressclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -m1 -i haproxy)
[ -n "$class" ] && ok "the HAProxy ingress class is $class" || bad "no HAProxy ingress class: $($K get ingressclass -o name 2>&1)"
$K create namespace ci-a2 >/dev/null 2>&1
$K apply -n ci-a2 -f - > "$W/k" 2>&1 <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: data }
spec: { accessModes: [ReadWriteOnce], storageClassName: longhorn, resources: { requests: { storage: 1Gi } } }
---
apiVersion: v1
kind: Pod
metadata: { name: writer }
spec:
  restartPolicy: Never
  containers:
    - { name: w, image: busybox:1.36, command: [sh, -c, "echo ci-a2-volume > /data/f && sync && cat /data/f"], volumeMounts: [{ name: d, mountPath: /data }] }
  volumes: [{ name: d, persistentVolumeClaim: { claimName: data } }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: web }
spec:
  replicas: 1
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
        - name: web
          image: busybox:1.36
          command: [sh, -c, "mkdir -p /www && echo ci-a2-web > /www/index.html && exec httpd -f -p 8080 -h /www"]
---
apiVersion: v1
kind: Service
metadata: { name: web }
spec: { selector: { app: web }, ports: [{ port: 80, targetPort: 8080 }] }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: web }
spec:
  ingressClassName: ${class:-haproxy}
  rules:
    - host: web.ci.test
      http: { paths: [{ path: /, pathType: Prefix, backend: { service: { name: web, port: { number: 80 } } } }] }
EOF
[ $? = 0 ] && ok "apply the test workload" || { bad "apply the test workload"; tail -5 "$W/k"; }
done_ok() { [ "$($K get pod -n ci-a2 writer -o jsonpath='{.status.phase}' 2>/dev/null)" = Succeeded ]; }
within 300 done_ok && [ "$($K logs -n ci-a2 writer 2>/dev/null)" = ci-a2-volume ] && ok "a pod writes to a Longhorn volume" \
  || { bad "the Longhorn writer pod: $($K get pod -n ci-a2 writer --no-headers 2>&1)"; $K get events -n ci-a2 --sort-by=.lastTimestamp 2>/dev/null | tail -4 | cut -c1-170; }
$K wait -n ci-a2 --for=condition=Available deployment/web --timeout=300s >/dev/null 2>&1 && ok "the web app is up" || bad "the web app isn't up"
web() { [ "$(curl -s -m 5 -H 'Host: web.ci.test' "http://${lbip:-$IP}/")" = ci-a2-web ]; }
if within 120 web; then
  ok "a request through the HAProxy ingress reaches the app"
else
  bad "the HAProxy ingress over HTTP: '$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H 'Host: web.ci.test' "http://${lbip:-$IP}/")'"
  # What it takes to tell a network fault from a routing one
  curl -sv -m 5 "http://${lbip:-$IP}/" 2>&1 | grep -E '^(< HTTP|\* (Connected|Empty|Recv|Failed|connect))' | head -3
  echo "  with Host web.ci.test: $(curl -s -m 10 -o /dev/null -w 'code %{http_code}, curl exit %{exitcode}, %{time_total}s' -H 'Host: web.ci.test' "http://${lbip:-$IP}/")"
  echo "  FORWARD policy: $(iptables -S FORWARD 2>/dev/null | head -1); docker: $(systemctl is-active docker 2>/dev/null)"
  $K get svc,pods -n haproxy-controller -o wide 2>&1 | cut -c1-160 | head -5
  $K logs -n haproxy-controller -l app.kubernetes.io/name=kubernetes-ingress --tail=6 2>&1 | cut -c1-170
fi
# TLS passthrough, the path DAP uses: HAProxy hands the TLS stream to the pod by SNI, and the pod's own certificate answers.
$K apply -n ci-a2 -f - > "$W/k2" 2>&1 <<TLSEOF
apiVersion: apps/v1
kind: Deployment
metadata: { name: tls }
spec:
  replicas: 1
  selector: { matchLabels: { app: tls } }
  template:
    metadata: { labels: { app: tls } }
    spec:
      containers:
        - name: tls
          image: alpine:3.20
          command: [sh, -c, "apk add -q --no-cache openssl >/dev/null && openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=tls.ci.test -keyout /k -out /c >/dev/null 2>&1 && exec openssl s_server -quiet -accept 8443 -cert /c -key /k -www"]
---
apiVersion: v1
kind: Service
metadata: { name: tls }
spec: { selector: { app: tls }, ports: [{ port: 443, targetPort: 8443 }] }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: { name: tls, annotations: { haproxy.org/ssl-passthrough: "true" } }
spec:
  ingressClassName: ${class:-haproxy}
  rules:
    - host: tls.ci.test
      http: { paths: [{ path: /, pathType: Prefix, backend: { service: { name: tls, port: { number: 443 } } } }] }
TLSEOF
$K wait -n ci-a2 --for=condition=Available deployment/tls --timeout=300s >/dev/null 2>&1 && ok "a TLS app is up" || bad "the TLS app isn't up"
tls_cn() { openssl s_client -connect "${lbip:-$IP}:443" -servername tls.ci.test </dev/null 2>/dev/null | openssl x509 -noout -subject 2>/dev/null; }
tls() { [[ "$(tls_cn)" == *tls.ci.test* ]]; }
within 120 tls && ok "TLS passthrough through HAProxy reaches the pod, whose own certificate answers" \
  || bad "TLS passthrough: the certificate at :443 for tls.ci.test is '$(tls_cn)'"
grep -q "https://$R" /etc/rancher/rke2/registries.yaml 2>/dev/null && ok "registries.yaml points at the registry" || bad "registries.yaml doesn't name the registry"
# Every page: a run makes more than 100 pull entries, and the first page holds only the newest.
pulls="" now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for page in $(seq 1 20); do
  p=$(h "https://$R/api/v2.0/auditlog-exts?page=$page&page_size=100&q=operation%3Dpull%2Cusername%3D$RU%2Cop_time%3D%5B$since~$now%5D")
  [ "$(grep -o '"operation":"pull"' <<< "$p" | wc -l)" -gt 0 ] || break
  pulls+="$p"
done
n=$(grep -o '"resource":"[a-z0-9-]*/[^"@:]*' <<< "$pulls" | sort -u | wc -l)
for ns in rancher haproxytech longhornio metallb; do
  grep -q "\"resource\":\"$ns/" <<< "$pulls" && ok "Harbor's audit log has this job pulling $ns images" || bad "Harbor's audit log has no $ns pull by this job"
done
echo "  ($n images pulled from the registry by this job)"
AP_ASSUME_YES=true ./ap-tools uninstall rke2 > "$W/o" 2>&1 && ok "ap-tools uninstall rke2" || { bad "ap-tools uninstall rke2"; show; }
systemctl is-active --quiet rke2-server && bad "rke2-server is still running" || ok "rke2-server is gone"
echo "=== exit $fail"; exit $fail
