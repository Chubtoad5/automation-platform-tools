# Container registry

DAP pulls its container images from an OCI registry. Two supported patterns:

## Option A — let ap-tools install Harbor
`sudo ./ap-tools install harbor` stands up Harbor on the host with a self-signed certificate and
pre-creates every project DAP needs. Defaults:
- Admin: `admin` / `Harbor12345` — **change it.**
- Hostname: `registry.<hostname>.<base-domain>` on port `8443`.

## Option B — use an existing external registry
Point ap-tools at any OCI registry with `-registry <host:port> <user> <pass>` (FQDN or IP + port, no
`https://`). You can pre-stage images with `ap-tools push -registry …`. An external registry must have
these project paths pre-created:

```
rancher  haproxytech  longhornio  metallb  frrouting  chrislusf
e2e-test-images  library  velero  grafana  prom  prometheus
prometheus-operator  kube-state-metrics  ingress-nginx  bats  kiwigrid  fluent
```

…plus a project for the DAP images themselves — the value of `REGISTRY_PROJECT_NAME` (default
`dell-automation`).

If the DAP images are already present in your registry and you don't want ap-tools to re-load them
during the bundle step, set `SKIP_IMAGES_LOADER=true`.
