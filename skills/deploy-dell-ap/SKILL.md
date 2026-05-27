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

1. **RKE2 cluster** — `install rke2` (add `-tls-san <cluster-name>` for multi-node).
2. **Registry** — either `install harbor` on this host, or point at an external registry you run.
3. *(multi-node only)* **join** each additional node — see [reference/topology.md](reference/topology.md).
4. **DAP bundle** — `install ap-bundle -registry <host:port> <user> <pass>` — stages the bundle.
5. **Run `install-upgrade.sh`** from the generated `ap-install-upgrade-cmd.txt` — this is what actually
   deploys DAP (20–40 min).
6. **Smoke-verify** — see "Verify, don't trust exit codes" below.

## The five things that trip people up

1. **`install ap-bundle` does NOT deploy DAP.** It stages the bundle and writes
   `ap-install-upgrade-cmd.txt`. You must then run the `install-upgrade.sh` command in that file.
2. **Exit code 0 can lie.** Several steps have fail-soft pod-readiness checks that warn and still
   return 0. Run the post-install smoke assertions (below), not just `echo $?`.
3. **Order matters.** RKE2 first, then registry, then ap-bundle. ap-tools installs its own HAProxy
   ingress — do not point it at a pre-existing cluster that already has a different ingress controller.
4. **DNS must resolve before `install ap-bundle`.** Its pre-flight aborts if the portal / orchestrator /
   `mtls-` records don't resolve. See [reference/dns-and-certs.md](reference/dns-and-certs.md).
5. **34 GB RAM, not 32.** RKE2 reserves ~2 GB; a 32 GB host fails the bundle's allocatable-capacity
   check. See [reference/prerequisites.md](reference/prerequisites.md).

## Reference material (read on demand)

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

## Scope — what this skill does NOT do
- It does **not** provision infrastructure (VMs, networks, DNS zones) — you create those first; the
  skill tells you what to create.
- It does **not** manage DAP after install (blueprints, day-2 operations).
- It does **not** modify the `ap-tools` script itself.
