# DNS and certificates

## Required DNS A records
Create these pointing at the **target host's IP** (substitute your own base domain for
`myhost.mydomain.lab`):

| Record | Purpose | Required? |
|:--|:--|:--|
| `portal.myhost.mydomain.lab` | DAP Portal endpoint | Yes |
| `orchestrator.myhost.mydomain.lab` | DAP Orchestrator endpoint | Yes |
| `mtls-orchestrator.myhost.mydomain.lab` | Device mTLS authentication | **Yes — hard requirement** |
| `mtls-recovery-orchestrator.myhost.mydomain.lab` | Device mTLS recovery | **Yes — hard requirement** |

- The `mtls-` / `mtls-recovery-` prefixes are not optional; Orchestrator device authentication fails
  without them.
- **Wildcard shortcut:** `*.myhost.mydomain.lab` → host IP satisfies all four at once.
- **Avoid** `.local` zones (mDNS conflict).
- DNS must resolve **before** `install ap-bundle` — its pre-flight aborts on unresolved names.

## Single-node DNS (the simple case)
One host, one IP. All four records (or a `*.<host>.<domain>` wildcard) point at that host's IP:

| Record | → |
|:--|:--|
| `portal.<host>.<domain>` | host IP |
| `orchestrator.<host>.<domain>` | host IP |
| `mtls-orchestrator.<host>.<domain>` | host IP |
| `mtls-recovery-orchestrator.<host>.<domain>` | host IP |

`HOST_FQDN` defaults to `<hostname>.<domain>`, so on a single node you usually don't set it.

## Multi-node DNS (the split that trips people up)
Multi-node has **two distinct addresses** and they must NOT be the same record:

1. **Ingress VIP** (`LB_IP`) — the MetalLB floating IP that fronts the **portal/orchestrator HTTPS**. The
   `portal.` / `orchestrator.` / `mtls-*` records point **here**.
2. **Cluster / API name** (`-tls-san`) — the Kubernetes API. **`ap-tools` does not load-balance the API**;
   this name must resolve to the **node IPs** (one A record per node — DNS round-robin), or to your own
   external API load balancer. It must **never** point at the ingress VIP, or node joins fail.

Worked example — cluster name `cl.example.lab`, nodes `.11/.12/.13`, ingress VIP `.20`:

| Record | Type | → | Role |
|:--|:--|:--|:--|
| `cl.example.lab` | A ×3 | `.11`, `.12`, `.13` | API / `-tls-san` (round-robin) |
| `*.cl.example.lab` | A | `.20` | ingress VIP — covers all four below |
| `portal.cl.example.lab` | (wildcard) | `.20` | DAP Portal |
| `orchestrator.cl.example.lab` | (wildcard) | `.20` | DAP Orchestrator |
| `mtls-orchestrator.cl.example.lab` | (wildcard) | `.20` | device mTLS |
| `mtls-recovery-orchestrator.cl.example.lab` | (wildcard) | `.20` | device mTLS recovery |
| `node1.example.lab` … | A | `.11` … | per-node host records (optional, nice for SSH) |

> A `*.cl.example.lab` wildcard → VIP covers the four service records cleanly, **and** the bare
> `cl.example.lab` stays a separate record set → node IPs (a wildcard does not match the bare name). That is
> exactly the split you want.

Then drive the install with: `-tls-san cl.example.lab`, `LB_IP=.20`, and **`HOST_FQDN=cl.example.lab` on
`install ap-bundle`** (so `PORTAL_FQDN`/`ORCHESTRATOR_FQDN` become `portal.cl.example.lab` etc. — matching the
wildcard → VIP). Without `HOST_FQDN`, the bundle pre-flight checks `portal.<hostname>` (e.g. `portal.node1…`)
and aborts. **Join via a node IP** (`join server .11 <token> …`), not the cluster name.

RKE2 only adds names you pass via `-tls-san` to the API-server certificate, so **join nodes using a node IP
or the `-tls-san` name — never an un-SAN'd node FQDN, and never the ingress VIP.**

## Trusting the registry CA
If you use a self-signed registry (e.g. ap-tools' Harbor), clients and the cluster must trust its CA.
ap-tools wires this up during install. For manual client trust, import the CA into the system store and
refresh:

- Ubuntu/Debian: `/usr/local/share/ca-certificates/` then `update-ca-certificates`
- RHEL family: `/etc/pki/ca-trust/source/anchors/` then `update-ca-trust extract`
- SLES family: `/etc/pki/trust/anchors/` then `update-ca-certificates`
- Docker engine: also copy the CA to `/etc/docker/certs.d/<host:port>/` and restart Docker.

The CA is downloadable from the Harbor host at `/data/ca_download/ca.crt`, or via
`curl -k https://<registry-host:port>/api/v2.0/systeminfo/getcert -o ca.crt`.
