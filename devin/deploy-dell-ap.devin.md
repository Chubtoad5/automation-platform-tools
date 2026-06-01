# Playbook: Deploy Dell Automation Platform (ap-tools)

## Overview
Install Dell Automation Platform (DAP) on-premise using the `ap-tools` script in this repository: an
RKE2 Kubernetes cluster, an optional Harbor registry, and the DAP bundle — single- or multi-node,
online or air-gapped. `ap-tools` runs as root on the target host; SSH in if you are working remotely.
This playbook mirrors `skills/deploy-dell-ap/SKILL.md`; see that skill's `reference/` files for detail.

## What's Needed From User
Collect ALL of the following before doing anything. Do not assume defaults for hosts, DNS, or credentials.
- Topology: single-node or multi-node (and how many control-plane vs worker nodes).
- Each target host: IP/FQDN, SSH user, and SSH auth (private-key path or password). Root/sudo required.
- Base domain, and confirmation these A records resolve to the host IP: `portal.`, `orchestrator.`,
  `mtls-orchestrator.`, `mtls-recovery-orchestrator.` (multi-node also needs a cluster/API name for
  `-tls-san`).
- Multi-node only: whether to use a dedicated floating ingress VIP (`LB_VIP`) — a free L2 IP, not a node
  IP — for HA. If used, `portal.`/`orchestrator.` DNS must point at the VIP.
- NTP: ask which NTP server(s) the nodes should use (`NTP_SERVERS`). Required for consistent time across
  nodes (etcd/TLS/tokens). If none supplied, confirm the hosts are already time-synced.
- Registry: install Harbor via ap-tools, or an external OCI registry (host:port + credentials, supplied
  at run time — never committed).
- Identity: organization name and description; admin first name, last name, username, email.
- Mode: online or air-gapped.
- Confirmation that each host meets 16 vCPU / 34 GB RAM / 500 GB+ disk and runs a supported OS.

## Procedure
- Collect every item in "What's Needed From User" and echo it back to the user as a plan.
- Wait for explicit user confirmation ("proceed") before changing anything.
- Run `bash skills/deploy-dell-ap/scripts/preflight.sh --dns <portal,orchestrator,mtls,mtls-recovery> [--multi-node]` on each host and resolve every failure.
- Clone or checkout this repository on the target host and run `chmod +x ap-tools`.
- Install the cluster: `sudo BASE_DOMAIN=<domain> [NTP_SERVERS=<servers>] ./ap-tools install rke2` (add `-tls-san <cluster-name>`, `CLUSTER_TYPE=multi-node`, and `LB_VIP=<free-ip>` for multi-node HA). Pass the same `NTP_SERVERS` on every node.
- If no external registry exists, run `sudo BASE_DOMAIN=<domain> ./ap-tools install harbor`.
- For multi-node, join each additional node with `sudo [NTP_SERVERS=<servers>] ./ap-tools join server|agent <node-ip-or-tls-san> <token> [-tls-san <cluster-name>]` (token at `/var/lib/rancher/rke2/server/node-token`; join via a node IP or the `-tls-san` name, not a node FQDN).
- Stage the bundle: `sudo BASE_DOMAIN=<domain> ORG_NAME=<org> EMAIL=<email> ./ap-tools install ap-bundle -registry <host:port> <user> <pass>`.
- Open `ap-install-upgrade-cmd.txt` and run the `install-upgrade.sh` command it contains; wait for `Installation has completed successfully` (20–40 minutes).
- Verify the install before reporting success (see Specifications).

## Specifications
- DAP Portal is reachable over HTTPS at `https://<portal-fqdn>` and serves a login page.
- All cluster nodes report `Ready` (`kubectl get nodes`); DAP pods are `Running`/`Completed` with no `CrashLoopBackOff` (`kubectl get pods -A`).
- The initial admin login `administrator` / `Temporary@123` works and forces a password change.
- No secret values were written to files in the repository.

## Forbidden Actions
- Do NOT skip the intake or assume host addresses, DNS names, or credentials.
- Do NOT run installs out of order — RKE2 must come first. ap-tools installs its own HAProxy ingress; do
  not point it at a pre-existing cluster that has a different ingress controller.
- Do NOT treat exit code 0 as success — verify the platform is actually up.
- Do NOT commit or hardcode secrets.
- Do NOT modify the `ap-tools` script.

## Advice and Pointers
- `install ap-bundle` stages the bundle and writes `ap-install-upgrade-cmd.txt`; it does not deploy DAP
  on its own — you must run the `install-upgrade.sh` command from that file.
- Use 34 GB RAM minimum, not 32 — RKE2 reserves ~2 GB and the bundle pre-check measures Kubernetes
  allocatable capacity.
- DNS must resolve before `install ap-bundle`. A wildcard `*.<host>.<domain>` is the easy way to satisfy
  all required records.
- The full CLI contract and a troubleshooting tree live in `skills/deploy-dell-ap/reference/`.
