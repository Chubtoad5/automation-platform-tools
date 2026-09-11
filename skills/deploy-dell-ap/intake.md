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
  - **If password auth:** confirm `sshpass` is installed on **your (controller) machine** — you'll need it
    to script the non-interactive SSH/SCP calls. Check with `command -v sshpass`; if missing, offer to install
    it (`sudo apt-get install -y sshpass` / `sudo dnf install -y sshpass` / `sudo zypper install -y sshpass`).
    With key auth you don't need it.
- Confirm the user has **root / sudo** on each host.

## 3. Base domain + DNS
- The base domain (e.g. `mydomain.lab`).
- Confirm these A records resolve to the host IP (the `mtls-` ones are **mandatory**):
  `portal.<...>`, `orchestrator.<...>`, `mtls-orchestrator.<...>`, `mtls-recovery-orchestrator.<...>`.
- **Multi-node:** also a shared cluster / API name to use as the `-tls-san` value. This name must resolve to
  the **node IPs** (round-robin), not the ingress VIP — `ap-tools` does not load-balance the API server.
- **Multi-node ingress VIP:** ask whether to use a **dedicated floating VIP** (`LB_IP`) — a free IP in the
  nodes' L2 subnet (outside any DHCP range), distinct from any node IP. Recommended for HA so the portal stays
  reachable if a node fails. If used, the `portal.*`/`orchestrator.*`/`mtls-*` records must point at the **VIP**,
  not a node IP. If declined, the ingress VIP defaults to the first node's IP (lost if that node goes down).
  (`LB_VIP` is a deprecated alias for `LB_IP`.) See [reference/topology.md](reference/topology.md).
- A wildcard `*.<cluster>` → the VIP covers the four service records, while the bare `<cluster>` name stays a
  separate record set → the node IPs. See [reference/dns-and-certs.md](reference/dns-and-certs.md).
- **No DNS server at all?** Offer `ap-tools install dns-server` (a Technitium DNS Server) on a **separate**
  small host — never on an RKE2 node. Then collect: that host's IP + SSH access; the zone (`DNS_ZONE`, default
  = base domain); the DAP host/cluster FQDN (`DNS_DAP_FQDN`) and its ingress IP (`DNS_DAP_IP` = host IP single-node,
  the VIP multi-node) plus the node IPs (`DNS_DAP_NODE_IPS`, multi-node); the registry / SeaweedFS IPs if those
  names should be seeded (`DNS_REGISTRY_IP` / `DNS_SWFS_IP`); upstream resolvers for everything else
  (`DNS_FORWARDERS`, empty in a closed air-gap); and the console password **by reference** (`DNS_ADMIN_PASSWORD`).
  Every DAP/registry host must then use that server as its resolver (`config static-ip … -dns <ip>`).
  See "Option B" in [reference/dns-and-certs.md](reference/dns-and-certs.md).

## 4. Container registry
- Install Harbor via ap-tools on this host, **or** use an external OCI registry?
- If external: `host:port`, username, password (by reference / at run time), and confirm the required
  project paths exist — see [reference/registry.md](reference/registry.md).
- **Does the registry already hold the images?** Ask two things:
  - **RKE2 / infra images** already mirrored? → pass `-registry` to `install rke2` so it pulls from the
    registry instead of the internet.
  - **DAP bundle images** already pushed? → set `SKIP_IMAGES_LOADER=true` at `install ap-bundle` so it
    doesn't re-push the ~126 images. If unsure, leave it `false` (the loader is idempotent but slower).

## 4b. DAP version + bundle source
- **Which DAP version?** Default is the version pinned in `ap-tools` (`AP_BUNDLE_URL`, currently v2.0.0.0).
  If the user wants a **different** version, ask for the bundle **URL** and pass it as `AP_BUNDLE_URL=<url>`.
- **Is the bundle already staged on the host**, or should the tool download it?
  - **Pre-staged:** place the `.zip` in the working dir and set `AP_BUNDLE_URL` to its filename/path — the
    tool uses it instead of downloading (~19 GB saved).
  - **Download:** the tool fetches `AP_BUNDLE_URL` during `install ap-bundle` (needs outbound internet;
    ~19 GB, 5–40 min). See [reference/commands.md](reference/commands.md).

## 4c. Dell Distributed Private Cloud (DDPC) add-on — ask, don't assume
- **Does the user also want DDPC** (Dell Distributed Private Cloud) on this DAP? It is an add-on bundle
  installed **into the running orchestrator** after DAP is up. Only if yes:
  - **Bundle source**: default pinned version (`DDPC_BUNDLE_URL`, currently 4.3.0.0), a different URL, or a
    pre-staged `.zip` in `ap-install/` (~6 GB saved).
  - **Registry for the DDPC images**: pass `-registry` (same or different registry/credentials), or omit it to
    reuse the orchestrator's `docker-secret` registry. If the 19 DDPC images are already there, set
    `DDPC_SKIP_IMAGES_LOADER=true`.
  - **DAP version pairing**: the bundle's required DAP version (default gate `DDPC_REQUIRED_DAP_VERSION=2.1.1.0`,
    exact match). If the user runs a different DAP version, confirm Dell supports the pairing before overriding.

## 5. Identity / organization (for DAP setup)
- Organization name and description.
- Admin first name, last name, username, and email.

## 6. Resource confirmation
- **Single-node:** confirm the host meets **18 vCPU / 36 GB RAM / 850 GB+ disk** (36, not 34 — the check
  measures *allocatable*). Prefer 1 TB of disk.
- **Multi-node:** confirm each node meets **16 vCPU / ≥ 20 GB RAM (3-node) / 850 GB+ disk**. 16 GB/node is
  **not** enough — a 16 GB × 3 cluster wedges the Orchestrator install at 90-99% memory. DAP applies its
  **850 GB ephemeral-storage requirement per node**, so every node needs it, not the cluster in aggregate.
  See [reference/prerequisites.md](reference/prerequisites.md).
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
    blueprint artifacts. **Multi-cluster:** to back up several clusters to one SeaweedFS, pre-create a
    bucket per cluster in one pass with `EXTRA_BUCKETS="<id1> <id2> …"` on the swfs install.
  - **Velero** (`install velero`) — cluster backups; needs an S3 endpoint (a SeaweedFS bucket is the
    intended backend) via `VELERO_S3_URL` / `VELERO_S3_ACCESS_KEY` / `VELERO_S3_SECRET_KEY`.
    **Multi-cluster: give each cluster its own bucket** — set `VELERO_BUCKET=<cluster-id>` (match
    `CLUSTER_NAME`). The installer prints a warning if `VELERO_BUCKET` is left at the default `velero`
    while `CLUSTER_NAME` is customised (avoids backup collision / an `Unavailable` BSL). Ask for the
    cluster id when velero is wanted in a multi-cluster environment.
  - **Monitoring** (`install monitoring`) — kube-prometheus-stack + Fluent Bit. Needs `MONITORING_HOST`
    (the shared SeaweedFS monitoring host running Loki/Grafana/Prometheus); `CLUSTER_NAME` labels this
    cluster's metrics and logs so multiple clusters can be filtered apart in Grafana/Loki.
  - **DDPC** (`install ddpc-bundle`) — see 4c. Runs after DAP is verified up; then run
    `ddpc-install-upgrade-cmd.txt`.

---

## Confirmation gate
Summarize every answer back to the user as a short plan, then get an explicit **"proceed"** before
running preflight or any install step.
