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
- Confirm each host meets **16 vCPU / 34 GB RAM / 500 GB+ disk** (34, not 32 — see
  [reference/prerequisites.md](reference/prerequisites.md)) and runs a supported OS.

## 7. Mode
- **Online** (internet-connected) or **air-gapped**? Air-gapped uses `offline-prep` on a connected host,
  then transfer + install. See [reference/commands.md](reference/commands.md).

---

## Confirmation gate
Summarize every answer back to the user as a short plan, then get an explicit **"proceed"** before
running preflight or any install step.
