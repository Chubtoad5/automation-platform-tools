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
11. **Wrong join target** — join via a node IP or the `-tls-san` name; reuse the same `-registry` /
    `-tls-san` on every node. See [topology.md](topology.md).

> Note: env-var overrides (`BASE_DOMAIN`, the identity vars, `SKIP_IMAGES_LOADER`, …) are honored on the
> current `main`. If an override seems ignored, update your checkout rather than editing the script.
