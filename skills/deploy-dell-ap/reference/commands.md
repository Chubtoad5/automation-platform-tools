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
| `install velero` | Velero backups to a SeaweedFS S3 bucket | `VELERO_S3_URL`, `VELERO_S3_ACCESS_KEY`, `VELERO_S3_SECRET_KEY` |
| `install monitoring` | kube-prometheus-stack + Fluent Bit | `MONITORING_HOST` |
| `install ap-bundle` | Stage the DAP bundle; emit `ap-install-upgrade-cmd.txt` | `-registry <host:port> <user> <pass>` |
| `offline-prep` | Build `ap-offline.tar.gz` for air-gapped install | none (needs internet) |
| `push` | Pull required images and push them to a registry | `-registry …` |
| `join server <fqdn> <token>` | Join a control-plane node | (optional `-tls-san`, `-registry`) |
| `join agent <fqdn> <token>` | Join a worker node | (optional `-registry`) |
| `upgrade rke2 <server\|agent\|both> <stable\|version>` | Upgrade cluster nodes | (optional `-registry`) |

## Options
- `-tls-san <fqdn-or-ip>` — extra Subject Alternative Name on the API-server cert. Required for
  multi-node. Valid with `install rke2`, `join server`.
- `-registry <host:port> <user> <pass>` — private registry (FQDN/IP + port, **no** `https://`). Valid
  with `install rke2`, `install ap-bundle`, `install swfs`, `push`, `join`, `upgrade rke2`.

## Install order
`rke2` → (`harbor` and/or `swfs`) → join nodes (multi-node) → `ap-bundle` → run `install-upgrade.sh`
→ optionally `velero`, `monitoring`.

## Key environment variables
Set inline, e.g. `sudo BASE_DOMAIN=mydomain.lab ./ap-tools install rke2`.

| Variable | Default | Notes |
|:--|:--|:--|
| `BASE_DOMAIN` | `edge.lab` | Base DNS domain for all service FQDNs. |
| `CLUSTER_TYPE` | `single-node` | Set `multi-node` before the first `install rke2`. |
| `RKE2_VERSION` | `v1.34.5+rke2r1` | RKE2 release to install. |
| `ORG_NAME` / `ORG_DESC` | `changeme` | DAP organization identity. |
| `FIRST_NAME` / `LAST_NAME` / `USERNAME` / `EMAIL` | see README | DAP admin identity. |
| `SKIP_IMAGES_LOADER` | `false` | `true` if the DAP images are already in your registry. |
| `DOWNLOAD_AP_BUNDLE` | `false` | `true` to download the (~19 GB) bundle during offline-prep/install. |
| `MGMT_IP` | auto-detected | Override on multi-homed hosts. |

> Env-var overrides for the above are honored on the current `main`. (Older revisions hardcoded some of
> them — if you are on an old checkout and an override is silently ignored, update the repo.)

## After install
- `install ap-bundle` writes `ap-install-upgrade-cmd.txt`. Read it, then run the `install-upgrade.sh`
  command it contains to actually deploy DAP (20–40 min). Watch for `Installation has completed
  successfully` in the output.
- Initial DAP login: `administrator` / `Temporary@123` (forces a password change on first login).

## Air-gapped
1. On a connected host of the **same OS family and version** as the target: `./ap-tools offline-prep`
   (optionally `DOWNLOAD_AP_BUNDLE=true`). Produces `ap-offline.tar.gz`.
2. Transfer `ap-offline.tar.gz` + `ap-tools` to the target.
3. On the target: `tar xzf ap-offline.tar.gz` then run `install …` as usual — offline mode is
   auto-detected by the presence of the archive.
