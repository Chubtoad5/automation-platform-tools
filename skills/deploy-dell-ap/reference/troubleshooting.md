# Troubleshooting

Walk this tree top-down; most failures match the early branches.

1. **SSH / auth** — if `ssh -o BatchMode=yes <user>@<host> 'echo ok'` fails, the problem is
   network/auth, not the install. Fix connectivity first.
2. **Not root** — every tool exits 1 if not run as root. Use `sudo`.
3. **Unsupported OS** — `/etc/os-release` `ID` must match one in
   [prerequisites.md](prerequisites.md). No workaround; use a supported distro.
4. **DNS not resolving** — `install ap-bundle` aborts if the portal / orchestrator / `mtls-` names don't
   resolve. Fix DNS (or `/etc/hosts`) first. See [dns-and-certs.md](dns-and-certs.md).
5. **Registry unreachable / cert untrusted** — verify with `curl -k https://<host:port>/v2/`. Ensure
   clients trust the registry CA. For an external registry, confirm the project paths exist
   ([registry.md](registry.md)).
6. **Ports already in use** — RKE2 6443 / 9345 / 10250; Harbor 443 / 8443; SeaweedFS 9333 / 8888 / 8333.
   Don't co-locate a registry or storage service on the RKE2 host.
7. **Insufficient capacity** — DAP needs ~16 vCPU and ~34 GB *allocatable*. A 32 GB host fails the
   pre-check because RKE2 reserves ~2 GB. Multi-node: ensure disk is large enough for Longhorn replica-3.
8. **"Succeeded" but not working** — fail-soft readiness checks return 0 even when pods crash. Run the
   smoke checks in SKILL.md ("Verify, don't trust exit codes").
9. **Not idempotent** — re-running `install` on a populated host usually fails (service running, port
   conflicts, config conflicts). Recovery: `rke2_installer.sh uninstall` (tears the cluster down) →
   clean residual files → re-run.
10. **Air-gap version skew** — save archives are OS-version-specific. Build the archive on a host
    matching the target's OS family **and** version.
11. **Wrong join target** — **join via the first server's node IP**, not the cluster/`-tls-san` name. That
    name usually resolves to the **ingress VIP** (which doesn't serve the RKE2 API/supervisor port 9345 → the
    `rke2-server` service fails to start) or round-robins across nodes. A node IP always works. Reuse the same
    `-registry` / `-tls-san` on every node. See [topology.md](topology.md).
11b. **`install ap-bundle` checks the wrong FQDNs (multi-node)** — the DNS pre-flight aborts on
    `portal.<hostname>` / `orchestrator.<hostname>` because `HOST_FQDN` defaulted to the node's hostname. Fix:
    re-run with `HOST_FQDN=<cluster-name>` so it checks `portal.<cluster-name>` etc. (the names your DNS
    actually has). See [dns-and-certs.md](dns-and-certs.md).
12. **Pods stuck in `Init:` with `exit status 32` / `Can't open blockdev`** — `multipathd` has claimed
    Longhorn's iSCSI `sd*` devices. Node prep disables/masks `multipathd` and blacklists `sd*`
    automatically; if you hit it on an existing/foreign node: `systemctl stop multipathd && multipath -F`,
    force-delete the stuck pods, then disable+mask `multipathd` and add an `sd*` `devnode` blacklist to
    `/etc/multipath.conf`.
13. **Clock skew** — etcd, TLS, and DAP tokens fail if nodes disagree on time. `install ap-bundle` reports
    NTP sync state; if unsynced, set `NTP_SERVERS` and re-run node prep (`install rke2` / `join`) or fix the
    OS time source. Verify with `timedatectl`.
14. **Ingress VIP unreachable after a node failure (multi-node)** — the VIP was a node IP. Use a dedicated
    `LB_IP` and repoint `portal.*`/`orchestrator.*` DNS at it so MetalLB can fail the VIP over. Remember the
    VIP is **ingress-only** — it is not the API server; the `-tls-san` cluster name still points at node IPs.
    See [topology.md](topology.md).

> Note: env-var overrides (`BASE_DOMAIN`, the identity vars, `SKIP_IMAGES_LOADER`, …) are honored on the
> current `main`. If an override seems ignored, update your checkout rather than editing the script.
