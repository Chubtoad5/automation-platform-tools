# Intake — collect and confirm before any action

Ask the user for each item below **before** running preflight or any install. Group the questions and
ask follow-ups when an answer is ambiguous. Default to single-node if the user is unsure.

> **Never store secret values in this repository or paste them into chat logs.** Collect a secret
> *reference* (a name or a path), or have the user supply the value at run time.

## 1. Topology
- **Single-node or multi-node?** If multi-node: how many nodes, and how many control-plane vs worker?
  See [reference/topology.md](reference/topology.md).

## 2. Target host(s)
- IP address or FQDN of each host.
- SSH username.
- **Authentication:** SSH key (path to the private key) **or** password? Ask which.
  - Verify reachability before proceeding, e.g.
    `ssh -o BatchMode=yes -o ConnectTimeout=5 <user>@<host> 'echo ok'`.
- Confirm the user has **root / sudo** on each host.

## 3. Base domain + DNS
- The base domain (e.g. `mydomain.lab`).
- Confirm these A records resolve to the host IP (the `mtls-` ones are **mandatory**):
  `portal.<...>`, `orchestrator.<...>`, `mtls-orchestrator.<...>`, `mtls-recovery-orchestrator.<...>`.
- **Multi-node:** also a shared cluster / API name to use as the `-tls-san` value.
- **Multi-node ingress VIP:** ask whether to use a **dedicated floating VIP** (`LB_VIP`) — a free IP in the
  nodes' L2 subnet (outside any DHCP range), distinct from any node IP. Recommended for HA so the portal stays
  reachable if a node fails. If used, the `portal.*`/`orchestrator.*` records must point at the **VIP**, not a
  node IP. If declined, the ingress VIP defaults to the first node's IP (lost if that node goes down).
  See [reference/topology.md](reference/topology.md).
- A wildcard `*.<host>.<domain>` is the easiest way to satisfy all of these.
  See [reference/dns-and-certs.md](reference/dns-and-certs.md).

## 4. Container registry
- Install Harbor via ap-tools on this host, **or** use an external OCI registry?
- If external: `host:port`, username, password (by reference / at run time), and confirm the required
  project paths exist — see [reference/registry.md](reference/registry.md).

## 5. Identity / organization (for DAP setup)
- Organization name and description.
- Admin first name, last name, username, and email.

## 6. Resource confirmation
- **Single-node:** confirm the host meets **16 vCPU / 34 GB RAM / 500 GB+ disk** (34, not 32).
- **Multi-node:** confirm each node meets **16 vCPU / ≥ 20 GB RAM (3-node) / 500 GB+ disk**. 16 GB/node is
  **not** enough — a 16 GB × 3 cluster wedges the Orchestrator install at 90-99% memory. See
  [reference/prerequisites.md](reference/prerequisites.md).
- Either way, confirm a supported OS.

## 7. Time synchronization (NTP)
- **Ask which NTP server(s) the nodes should use.** Accurate, consistent time across nodes is required —
  skew breaks etcd quorum, TLS validation, and DAP tokens. If the user has a preferred/internal NTP source
  (common in air-gapped or enterprise environments), collect it and pass it as `NTP_SERVERS` (space/comma
  separated) so it is applied on **every** node during `install rke2` / `join` and verified during
  `install ap-bundle`. If the user has no preference and the hosts already sync via the OS default, you may
  leave it unset — but still confirm the hosts are currently time-synced before installing.

## 8. Mode
- **Online** (internet-connected) or **air-gapped**? Air-gapped uses `offline-prep` on a connected host,
  then transfer + install. See [reference/commands.md](reference/commands.md).

## 9. Optional add-ons (post-install) — ask, don't assume
- These are **not** part of deploying DAP and DAP does not depend on them. Ask only whether the user
  also wants any of them; install after DAP is verified up. See "Optional add-ons" in
  [SKILL.md](SKILL.md) and [reference/commands.md](reference/commands.md).
  - **SeaweedFS** (`install swfs`) — artifact storage (S3 / Filer, optional SMB/NFS), e.g. day-2
    blueprint artifacts.
  - **Velero** (`install velero`) — cluster backups; needs an S3 endpoint (a SeaweedFS bucket is the
    intended backend).
  - **Monitoring** (`install monitoring`) — kube-prometheus-stack + Fluent Bit.

---

## Confirmation gate
Summarize every answer back to the user as a short plan, then get an explicit **"proceed"** before
running preflight or any install step.
