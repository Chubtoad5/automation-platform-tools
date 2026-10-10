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
7. **Insufficient capacity** — DAP needs ~18 vCPU, ~34 GB *allocatable*. A 32 GB host fails the
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
15. **`install-upgrade.sh` aborts with "Invalid parameter format" / a multi-word value splits** — the
    generated `ap-install-upgrade-cmd.txt` quotes values on the current `ap-tools`; on an **older checkout**
    a multi-word `ORG_DESC`/`FIRST_NAME` is emitted unquoted (e.g. `ORG_DESC=Acme Edge Team`) and word-splits
    on run. Fix: quote each multi-word value when you run the block (`ORG_DESC="Acme Edge Team"`), or update
    `ap-tools`.
16. **DAP pods stall in `CreateContainerConfigError` / `Init:0/1` (multi-node)** — DAP bootstraps through a
    long secret/config dependency cascade (cert-manager mTLS secrets → NATS → postgres → keycloak client
    creds). A pod can sit in kubelet's **config-error backoff** for minutes *after* its secret/configmap
    actually exists. This is normal for a multi-node bring-up. First confirm the dependency is really present
    (`kubectl get secret/configmap …`), then `kubectl delete pod <stuck-pod>` — the controller recreates it
    and it mounts cleanly, clearing the backoff. Watch, don't assume the installer's wait will always ride
    it out.
17. **`ReplicaSchedulingFailure: insufficient storage` (multi-node Longhorn)** — large replica-3 volumes
    (e.g. OpenSearch/vmstorage, tens of GB each) can fail to schedule on **500 GB-class nodes**: the tool sets
    Longhorn `storage-over-provisioning-percentage=200`, and DAP's total scheduled allocation can exceed that
    against a 500–600 GB disk. Remedy: provision **≥1 TB/node** (recommended for multi-node), or raise the
    setting — `kubectl patch settings.longhorn.io storage-over-provisioning-percentage --type=merge -p '{"value":"400"}'`
    (Longhorn volumes are thin-provisioned, so real usage stays far below the allocation). See
    [prerequisites.md](prerequisites.md).

18. **`install ddpc-bundle` pre-flight fails** — read the first `Error:` line; each check names its fix:
    *DAP version mismatch* → the bundle pairs with `DDPC_REQUIRED_DAP_VERSION` (default 2.1.1.0); upgrade DAP or,
    only if Dell supports the pairing, override the variable. *Unhealthy pods / release not `deployed`* → DAP is
    not finished or is degraded (e.g. Longhorn volumes re-attaching after a node freeze/reboot) — wait for
    `kubectl get pods -A` to settle, then re-run. *ORCHESTRATOR_FQDN not served by any ingress* → set
    `HOST_FQDN`/`ORCHESTRATOR_FQDN` to the values used at `install ap-bundle` (multi-node: the cluster name).
    *Registry not reachable / credentials rejected* → check `curl -k https://<host:port>/v2/`; without
    `-registry` the registry CA must already be trusted by the host (it is after `install ap-bundle`).
    *Headroom* → DAP has committed most of the node; free capacity or lower the `DDPC_REQUIRED_*` gates
    knowingly. *Leftover NE-service pods* → the orchestrator still deploys its own NE services; Dell's
    installer refuses this state.
19. **DDPC `install-upgrade.sh` fails or stalls** — its logs are under `ap-install/ddpc-bundle/logs/`
    (`script_execution_*.log`, `distpvtcloud-install-helm-output-*.log`, per-image `image-loader_*` logs). A
    push failure is retried per image (`DDPC_IMAGE_LOADER_MAX_RETRIES`); a helm timeout (`INSTALL_TIMEOUT`,
    default 600 s) leaves the release `failed` — simply re-run the same command: the image push is skipped
    (recorded in the `distpvtcloud-image-push-status` configmap) and helm retries the install.

20. **A node is hard-down and pods stay `Terminating` / portal login fails (multi-node) — DAP 2.1.1.0 issue.**
    Seen on DAP **2.1.1.0** (3 nodes, Longhorn 1.11) after a node was powered off. Three separate things happen:
    - **Pods with Longhorn volumes recover by themselves.** ap-tools sets Longhorn
      `nodeDownPodDeletionPolicy: delete-statefulset-pod`, so Longhorn force-deletes those pods about 5–7 min
      after the node goes `NotReady` and they restart on a surviving node.
    - **StatefulSet pods without volumes stay `Terminating` until the node returns.** On 2.1.1.0 these are
      `dell-portal/dsp-iam-login-svc-*` (Keycloak) and `dell-orchestrator/hzp-eoproxy-svc-*`. Kubernetes never
      force-deletes a StatefulSet pod on an unreachable node, and Longhorn only acts on pods with its volumes.
      Both run several replicas, so service continues on the others. To clear them while the node stays down,
      **first confirm the node is really powered off** (hypervisor or BMC; a node that only lost its network
      would keep running the old pod beside the new one), then apply the Kubernetes non-graceful-shutdown taint:
      ```bash
      kubectl taint node <dead-node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
      # Kubernetes force-deletes its pods and detaches its volumes; replacements schedule elsewhere.
      # Once the node is back up and Ready, remove the taint (trailing '-'):
      kubectl taint node <dead-node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-
      ```
      Don't leave the taint on a running node: nothing without a matching toleration will schedule there.
    - **Portal login can stay down even after every node is healthy (DAP 2.1.1.0 defect).** If Keycloak logs
      `Could not find a server with specified targetServerType: primary`, the portal Postgres failed over and
      `postgresql-postgresql-0` is no longer the primary. pgpool relays `in_hot_standby` from node 0, and
      Keycloak refuses a standby. Neither the taint nor time fixes this. Check with
      `kubectl -n dell-portal exec postgresql-postgresql-0 -c postgresql -- /opt/bitnami/scripts/postgresql-repmgr/entrypoint.sh repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf cluster show`.
      If node 0 is a standby, make it primary again (about 15 min of portal database downtime):
      1. `kubectl -n dell-portal scale sts postgresql-postgresql --replicas=1`
      2. In `postgresql-postgresql-0`, run `… repmgr -f /opt/bitnami/repmgr/conf/repmgr.conf standby promote`,
         then `… primary register --force`. Use the same `entrypoint.sh repmgr` wrapper as above. The pod may
         crash-loop, so run each command while the container is up.
      3. `kubectl -n dell-portal scale sts postgresql-postgresql --replicas=3`. Nodes 1 and 2 rejoin as
         standbys within a few minutes and login recovers.

      Don't try to force it by deleting the primary pod: it returns within repmgr's 200 s failover window, so
      nothing changes. `repmgr standby switchover` is unavailable because the image has no `ssh`. It is a defect
      in the bundled Postgres/pgpool/Keycloak, not in ap-tools.

> Note: env-var overrides (`BASE_DOMAIN`, the identity vars, `SKIP_IMAGES_LOADER`, …) are honored on the
> current `main`. If an override seems ignored, update your checkout rather than editing the script.
