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

## Multi-node: the cluster / API name
For multi-node you also need a name that represents the cluster API, used as the `-tls-san` value on the
first server and on every joined server. Point it at the control-plane node IP(s), or at a VIP / load
balancer if you have one. RKE2 only adds names you pass via `-tls-san` to the API-server certificate, so
**join nodes using a node IP or the `-tls-san` name — never an un-SAN'd node FQDN.**

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
