# ap-tools CLI contract

> A snapshot of the `ap-tools` interface for agent use. The live `ap-tools -h` output and the
> repository `README.md` are the source of truth — if they disagree with this file, trust them.

Run as **root** on the target host. Air-gapped mode is auto-detected when `ap-offline.tar.gz` is present
in the working directory.

## Synopsis
```
ap-tools [COMMAND] [OPTIONS]
```

## Commands
| Command | Purpose | Required |
|:--|:--|:--|
| `install rke2` | RKE2 cluster + MetalLB + HAProxy ingress + Longhorn + k9s | none (optional `-tls-san`, `-registry`, `push`) |
| `install harbor` | Harbor registry with self-signed certs + projects | none |
| `install swfs` | Single-node SeaweedFS (S3 / Filer, optional SMB/NFS) | none (optional `-registry`, `push`) |
| `install velero` | Velero backups to a SeaweedFS S3 bucket | `VELERO_S3_URL`, `VELERO_S3_ACCESS_KEY`, `VELERO_S3_SECRET_KEY` (multi-cluster: also `VELERO_BUCKET=<cluster-id>`) |
| `install monitoring` | kube-prometheus-stack + Fluent Bit | `MONITORING_HOST` |
| `install ap-bundle` | Stage the DAP bundle; emit `ap-install-upgrade-cmd.txt` | `-registry <host:port> <user> <pass>` |
| `install ddpc-bundle` | Stage the Dell Distributed Private Cloud add-on on a running DAP; pre-checks cluster/DAP version/registry/headroom; emit `ddpc-install-upgrade-cmd.txt` | none (optional `-registry …`; omitted = reuse the orchestrator `docker-secret` registry). DAP must already be deployed and healthy. |
| `uninstall ddpc-bundle` | Remove the DDPC staging (bundle tree + cmd file) and print Dell's in-cluster uninstall commands | none |
| `offline-prep` | Build `ap-offline.tar.gz` for air-gapped install | none (needs internet) |
| `push` | Pull required images and push them to a registry | `-registry …` |
| `join server <fqdn> <token>` | Join a control-plane node | (optional `-tls-san`, `-registry`) |
| `join agent <fqdn> <token>` | Join a worker node | (optional `-registry`) |
| `upgrade rke2 <server\|agent\|both> <stable\|version>` | Upgrade cluster nodes | (optional `-registry`) |

## Options
- `-tls-san <fqdn-or-ip>` — extra Subject Alternative Name on the API-server cert. Required for
  multi-node. Valid with `install rke2`, `join server`.
- `-registry <host:port> <user> <pass>` — private registry (FQDN/IP + port, **no** `https://`). Valid
  with `install rke2`, `install ap-bundle`, `install ddpc-bundle`, `install swfs`, `push`, `join`, `upgrade rke2`.

## Install order
`rke2` → (`harbor` and/or `swfs`) → join nodes (multi-node) → `ap-bundle` → run `install-upgrade.sh`
→ optionally `ddpc-bundle` → run its `install-upgrade.sh` → optionally `velero`, `monitoring`.

## Key environment variables
Set inline, e.g. `sudo BASE_DOMAIN=mydomain.lab ./ap-tools install rke2`.

| Variable | Default | Notes |
|:--|:--|:--|
| `BASE_DOMAIN` | `edge.lab` | Base DNS domain for all service FQDNs. |
| `CLUSTER_TYPE` | `single-node` | Set `multi-node` before the first `install rke2`. |
| `HOST_FQDN` | `<hostname>.<BASE_DOMAIN>` | Base FQDN the portal/orchestrator/`mtls-*` names derive from. **Multi-node: set this to the cluster name on `install ap-bundle`** so those FQDNs match the DNS pointing at the ingress VIP (else the pre-flight checks `portal.<hostname>` and aborts). |
| `LB_IP` | host `MGMT_IP` | The MetalLB **ingress** VIP (portal/orchestrator HTTPS). Single-node: leave default (= host IP). Multi-node: set to a dedicated free L2 IP (not a node IP). **Not** an API-server LB. |
| `LB_VIP` | _(empty)_ | **Deprecated alias for `LB_IP`** — still honored if set, but prefer `LB_IP`. |
| `NTP_SERVERS` | _(empty)_ | NTP server(s) to configure on every node (`install rke2`/`join`) and verify at `install ap-bundle`. Empty = OS default. |
| `RKE2_VERSION` | `v1.34.5+rke2r1` | RKE2 release to install. |
| `AP_BUNDLE_URL` | pinned (v2.1.1.0) | DAP bundle URL. Override to deploy a different version, or point at a pre-staged `.zip` filename in the working dir to skip the download. |
| `DDPC_BUNDLE_URL` | pinned (v4.3.0.0) | DDPC add-on bundle URL (~6 GB), or a pre-staged `.zip` filename in the working dir. |
| `DDPC_REQUIRED_DAP_VERSION` | `2.1.1.0` | Exact DAP orchestrator version the DDPC pre-flight requires (`any` disables the gate). |
| `DDPC_SKIP_IMAGES_LOADER` | `$SKIP_IMAGES_LOADER` | `true` if the DDPC images are already in the registry. |
| `DDPC_IMAGE_LOADER_PARALLEL_JOBS` / `DDPC_IMAGE_LOADER_MAX_RETRIES` | `5` / `3` | DDPC image-push parallelism and per-image retries. |
| `DDPC_INSTALL_TYPE` / `DDPC_INSTALL_TIMEOUT` / `DDPC_LOG_LEVEL` | `KUBERNETES` / `600` / _(empty)_ | Pass-throughs to DDPC's installer (`INSTALL_TYPE`, `INSTALL_TIMEOUT`, env-only `LOG_LEVEL`). |
| `DDPC_REQUIRED_CPU_HEADROOM` / `DDPC_REQUIRED_MEM_HEADROOM_GB` / `DDPC_REQUIRED_DISK_GB` | `2` / `4` / `25` | DDPC pre-flight gates: **unrequested** cores/GB the cluster must have free, and free disk under `ap-install/`. |
| `DOWNLOAD_DDPC_BUNDLE` | `false` | `true` to include the DDPC bundle in `offline-prep`. |
| `ORG_NAME` / `ORG_DESC` | `changeme` | DAP organization identity. |
| `FIRST_NAME` / `LAST_NAME` / `USERNAME` / `EMAIL` | see README | DAP admin identity. |
| `SKIP_IMAGES_LOADER` | `false` | `true` if the DAP images are already in your registry (skips re-pushing ~126 images at `install ap-bundle`). |
| `DOWNLOAD_AP_BUNDLE` | `false` | `true` to download the (~19 GB) bundle during offline-prep/install. |
| `MGMT_IP` | auto-detected | Override on multi-homed hosts. |

> Env-var overrides for the above are honored on the current `main`. (Older revisions hardcoded some of
> them — if you are on an old checkout and an override is silently ignored, update the repo.)

## After install
- `install ap-bundle` writes `ap-install-upgrade-cmd.txt`. Read it, then run the `install-upgrade.sh`
  command it contains to actually deploy DAP (20–40 min). Watch for `Installation has completed
  successfully` in the output.
- Initial DAP login: `administrator` / `Temporary@123` (forces a password change on first login).
- `install ddpc-bundle` writes `ddpc-install-upgrade-cmd.txt`. Run the command it contains to deploy DDPC into
  the orchestrator (10–25 min: image push + helm). Watch for `Installation has completed successfully`; then
  `helm ls -n dell-orchestrator` must show `dell-distributed-private-cloud` as `deployed`. Re-running the
  same command is safe (same version → skipped; failed → retried).

## Air-gapped
1. On a connected host of the **same OS family and version** as the target: `./ap-tools offline-prep`
   (optionally `DOWNLOAD_AP_BUNDLE=true`, and `DOWNLOAD_DDPC_BUNDLE=true` for the DDPC add-on). Produces
   `ap-offline.tar.gz`.
2. Transfer `ap-offline.tar.gz` + `ap-tools` to the target.
3. On the target: `tar xzf ap-offline.tar.gz` then run `install …` as usual — offline mode is
   auto-detected by the presence of the archive.
