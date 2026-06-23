---
name: deploy-dell-ap
description: Deploy Dell Automation Platform (DAP) on-premise using the ap-tools script in this repo — provisions an RKE2 Kubernetes cluster, an optional Harbor registry, and the DAP bundle on Linux host(s) you provide. Use when a user wants to install, stand up, or set up Dell Automation Platform / DAP on one or more Linux hosts — single-node or multi-node, online or air-gapped. The skill interviews the user for topology, host/SSH access, DNS, registry, and identity, confirms a plan, runs a preflight check, then installs in the correct order.
---

# Deploy Dell Automation Platform (ap-tools)

This skill drives an end-to-end Dell Automation Platform (DAP) install using the `ap-tools` script in
this repository. It is **environment-agnostic** — it makes no assumption about your hypervisor or cloud.
You bring a Linux host (or hosts) and DNS; the skill does the rest.

`ap-tools` runs as **root on the target host itself**. If you (the agent) are working from a different
machine, SSH into the target to run each step.

## Lead with this — show the user the shape of the job before interviewing

Before the first intake question, give the user a quick orientation so they know what they are signing up
for. Surface these three things up front (details in the linked references):

**1. The phases you will run** (what actually happens, in order):

| # | Phase | What runs | Where | Rough time |
|:--|:--|:--|:--|:--|
| 0 | Preflight | `scripts/preflight.sh` (OS/CPU/RAM/disk/DNS) | every node | seconds |
| 1 | RKE2 cluster | `install rke2` (+`-tls-san` multi-node) | first node | 5–15 min |
| 2 | Registry | `install harbor` **or** point at an external registry | first node / external | 0–10 min |
| 3 | Join nodes *(multi-node)* | `join server …` on each extra node | nodes 2..N | 2–5 min/node |
| 4 | Stage DAP bundle | `install ap-bundle -registry …` (writes `ap-install-upgrade-cmd.txt`) | a control-plane node | 5–40 min (download) |
| 5 | Deploy DAP | run `install-upgrade.sh` from that file | same node | 20–40 min |
| 6 | Verify | nodes/pods/portal smoke (don't trust exit 0) | from any node | minutes |

**2. The hard prerequisites** (the install aborts without them — see [reference/prerequisites.md](reference/prerequisites.md)
and [reference/dns-and-certs.md](reference/dns-and-certs.md)): the right-sized host(s); the four DNS records
(`portal.` / `orchestrator.` / `mtls-orchestrator.` / `mtls-recovery-orchestrator.`) resolving **before** phase 4;
a reachable OCI registry; accurate NTP; and — if you connect over SSH with a **password** — `sshpass` on **your**
(controller) machine. Offer to install it (`apt-get install -y sshpass` / `dnf install -y sshpass`); with an SSH
key you don't need it.

**3. What to build if the host(s) don't exist yet** (you provision these — the skill does not):

| Topology | Build | Per-node size | Extra |
|:--|:--|:--|:--|
| Single-node | 1 VM, static IP | **18 vCPU / 34 GB / 1 TB** (16/34/500 floor) | 4 DNS records → host IP |
| Multi-node (3) | 3 VMs, static IPs | **16 vCPU / 20 GB / 500 GB+** each | + **1 free ingress VIP IP** (not a node IP); DNS split (see below) |
| All-in-one | 1 VM | **20 vCPU / 40 GB / 1 TB** | co-locates Harbor+SeaweedFS |

## Run this skill in three phases — never install before intake is confirmed

### Phase A — Intake (gather requirements) FIRST
**STOP.** Collect every input listed in [intake.md](intake.md) before taking any action. Ask the user
directly, one group at a time. Do **not** assume defaults for host addresses, DNS names, or
credentials — if something is missing, ask.

### Phase B — Confirm, then preflight
1. Echo the collected configuration back to the user as a short plan and **wait for an explicit
   "proceed"** before changing anything.
2. Run the preflight validator on each target host and resolve every failure before continuing:
   ```bash
   bash scripts/preflight.sh --dns portal.<domain>,orchestrator.<domain>,mtls-orchestrator.<domain>,mtls-recovery-orchestrator.<domain> [--multi-node]
   ```
   It checks OS support, CPU/RAM/disk, and DNS resolution, and exits non-zero on any gap.

### Phase C — Execute in dependency order
Never skip RKE2 first. The exact flags and env vars are in
[reference/commands.md](reference/commands.md) — read it; do not guess flag names.

1. **RKE2 cluster** — `install rke2` (add `-tls-san <cluster-name>` for multi-node; set `CLUSTER_TYPE=multi-node`
   and, for a dedicated ingress VIP, `LB_IP=<vip>` — see the multi-node box below).
2. **Registry** — either `install harbor` on this host, or point at an external registry you run. If the
   registry **already holds** the RKE2 images, pass `-registry` to `install rke2`; if it already holds the DAP
   images, set `SKIP_IMAGES_LOADER=true` at phase 4 so the bundle step doesn't re-push them.
3. *(multi-node only)* **join** each additional node — see [reference/topology.md](reference/topology.md).
   **Join via a node IP** (the first server's IP), not the cluster/VIP name.
4. **DAP bundle** — `install ap-bundle -registry <host:port> <user> <pass>` — stages the bundle.
   **Multi-node: pass `HOST_FQDN=<cluster-name>`** so the portal/orchestrator FQDNs match the DNS you created
   (see the box below) — otherwise the DNS pre-flight checks `portal.<hostname>` and aborts.
5. **Run `install-upgrade.sh`** from the generated `ap-install-upgrade-cmd.txt` — this is what actually
   deploys DAP (20–40 min). It inherits `EO_HOST`/`PORTAL_HOST` from the `HOST_FQDN` you set in step 4.
6. **Smoke-verify** — see "Verify, don't trust exit codes" below.

### Multi-node: VIP, DNS split, and HOST_FQDN (read before phases 1/3/4)
The single thing that most often breaks a multi-node install is conflating two different addresses:

- **Ingress VIP (`LB_IP`)** — fronts the **portal/orchestrator HTTPS** only, via MetalLB. This is the *only*
  VIP `ap-tools` manages. `portal.` / `orchestrator.` / `mtls-*` DNS point **here**.
- **Cluster / API name (`-tls-san`)** — the Kubernetes API. **`ap-tools` does NOT load-balance the API server.**
  This name must resolve to the **node IPs** (e.g. 3 A records, one per node), or to your own external LB — *never*
  to the ingress VIP. Joining nodes connect to the API, so a cluster name pointing at the ingress VIP fails the join.

So a 3-node cluster needs a **DNS split** (full example in [reference/dns-and-certs.md](reference/dns-and-certs.md)):

| Name | Resolves to | Used by |
|:--|:--|:--|
| `portal.<cluster>` / `orchestrator.<cluster>` / `mtls-orchestrator.<cluster>` / `mtls-recovery-orchestrator.<cluster>` | **ingress VIP** (`LB_IP`) | DAP UI / device mTLS |
| `<cluster>` (the bare `-tls-san` name) | **the node IPs** (round-robin) | Kubernetes API |

Then: phase 1 `install rke2 -tls-san <cluster>` with `CLUSTER_TYPE=multi-node LB_IP=<vip>`; phase 3 `join server <first-node-IP> <token> -tls-san <cluster>`; phase 4 `HOST_FQDN=<cluster> install ap-bundle …`.

## The six things that trip people up

1. **`install ap-bundle` does NOT deploy DAP.** It stages the bundle and writes
   `ap-install-upgrade-cmd.txt`. You must then run the `install-upgrade.sh` command in that file.
2. **Exit code 0 can lie.** Several steps have fail-soft pod-readiness checks that warn and still
   return 0. Run the post-install smoke assertions (below), not just `echo $?`.
3. **Order matters.** RKE2 first, then registry, then ap-bundle. ap-tools installs its own HAProxy
   ingress — do not point it at a pre-existing cluster that already has a different ingress controller.
4. **DNS must resolve before `install ap-bundle`.** Its pre-flight aborts if the portal / orchestrator /
   `mtls-` records don't resolve. **Multi-node:** it derives them from `HOST_FQDN`, so set
   `HOST_FQDN=<cluster-name>` (step 4 above). See [reference/dns-and-certs.md](reference/dns-and-certs.md).
5. **The VIP is for ingress, not the API.** `LB_IP` fronts only the portal/orchestrator. The `-tls-san`
   cluster name must resolve to node IPs and you **join via a node IP** — see the multi-node box above.
6. **34 GB RAM single-node, 20 GB/node multi-node — not 32 / not 16.** RKE2 reserves ~2 GB; a 32 GB single
   host fails the bundle's allocatable check, and 16 GB/node wedges the Orchestrator. A node provisioned at
   exactly the floor reports ~1 GB less (firmware/kernel reserve); the preflight tolerates that. See
   [reference/prerequisites.md](reference/prerequisites.md).

## Reference material (read on demand)

- [dap-deploy-template.env](dap-deploy-template.env) — a fill-in-the-blank worksheet for every intake
  answer; offer it to the user to collect requirements (no secret values).

- [reference/prerequisites.md](reference/prerequisites.md) — host sizing, supported OS, what YOU must
  provision (this skill does not create infrastructure).
- [reference/dns-and-certs.md](reference/dns-and-certs.md) — required DNS records, the `mtls-` rule,
  the wildcard option, `-tls-san`, trusting the registry CA.
- [reference/topology.md](reference/topology.md) — single vs multi-node decision and the join model.
- [reference/registry.md](reference/registry.md) — ap-tools Harbor vs an external registry, and the
  project list an external registry must have.
- [reference/commands.md](reference/commands.md) — the full ap-tools CLI contract.
- [reference/troubleshooting.md](reference/troubleshooting.md) — failure tree, top-down.

## Verify, don't trust exit codes

After `install-upgrade.sh` reports `Installation has completed successfully`, confirm the platform is
actually up before telling the user "done":
- All nodes `Ready`: `kubectl get nodes`
- DAP pods `Running`/`Completed`, none `CrashLoopBackOff`: `kubectl get pods -A`
- Portal answers over HTTPS at `https://<portal-fqdn>` and serves a login page.
- Initial login `administrator` / `Temporary@123` works and forces a password change.

## Optional add-ons (after DAP is up)

None of these are required to deploy DAP, and DAP never consumes them at install time — install them
**only if the user asks**, and only after the platform is verified up. The full flags are in
[reference/commands.md](reference/commands.md).

- **`install swfs`** — a single-node SeaweedFS instance (S3 / Filer, optional SMB/NFS) for **artifact
  storage**, e.g. day-2 blueprint artifacts. Standalone — DAP does not depend on it. Can run on this host
  or a separate one.
- **`install velero`** — cluster backups via Velero with Longhorn CSI snapshots. Needs an S3 endpoint
  (`VELERO_S3_URL` / `VELERO_S3_ACCESS_KEY` / `VELERO_S3_SECRET_KEY`) — a SeaweedFS S3 bucket is the
  intended backend, so this typically follows `install swfs`. **Multi-cluster:** give each cluster its own
  bucket — set `VELERO_BUCKET=<cluster-id>` (and `CLUSTER_NAME` to match). The installer prints a warning if
  `VELERO_BUCKET` is left at the default `velero` while `CLUSTER_NAME` is customised. Pre-create the buckets
  on SeaweedFS with `EXTRA_BUCKETS="<id1> <id2> …"` on `install swfs`.
- **`install monitoring`** — kube-prometheus-stack + Fluent Bit. Requires `MONITORING_HOST` (the shared
  SeaweedFS host running Loki/Grafana/Prometheus). **Multi-cluster:** set `CLUSTER_NAME=<cluster-id>` so
  this cluster's metrics and logs are labelled and can be filtered apart from other clusters in Grafana/Loki.

Suggested order when used: install `swfs` any time after `rke2`; install `velero` / `monitoring` after
DAP is verified up.

## Scope — what this skill does NOT do
- It does **not** provision infrastructure (VMs, networks, DNS zones) — you create those first; the
  skill tells you what to create.
- It does **not** manage DAP after install (blueprints, day-2 operations).
- It does **not** modify the `ap-tools` script itself.
