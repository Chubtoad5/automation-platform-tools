# Changelog — automation-platform-tools

## 2026-10-10 — Docs: node hard-down troubleshooting for DAP 2.1.1.0 (docs/node-down-dap-2110)

Documentation only; no script change. From the first 3-node DAP 2.1.1.0 + DDPC node-failure test.

### Added
- README "Node hard-down: stuck pods and portal login (DAP 2.1.1.0)" and skill troubleshooting #20. When a
  node is confirmed powered off, `kubectl taint node <n> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute`
  clears the volume-less StatefulSet pods (`dsp-iam-login-svc`, `hzp-eoproxy-svc`) stuck `Terminating`.
  Remove the taint once the node is back.
- The DAP 2.1.1.0 defect where portal login fails whenever `postgresql-postgresql-0` is not the Postgres
  primary (pgpool relays `in_hot_standby` from node 0; Keycloak needs a primary), with the manual
  re-promotion procedure.

### Changed
- The README and `topology.md` now say that Longhorn `nodeDownPodDeletionPolicy: delete-statefulset-pod` only
  covers pods with Longhorn volumes. `topology.md` no longer promises "no manual steps after a node fails".

## 2026-09-11 — `install dns-server`: Technitium DNS Server as an ap-tools component (feature/dns-server)

Adds the sibling [technitium-dns-installer](https://github.com/Chubtoad5/technitium-dns-installer) as a
first-class component, so a site with no DNS can get the records DAP requires from ap-tools itself, online
or air-gapped. The installer is consumed through its documented contract (`install` / `save` / `uninstall`,
env-driven, sentinel-detected offline mode); nothing in it changed.

### Added
- **`install dns-server`.** Installs a bare-metal Technitium DNS Server on the current host via
  `technitium_dns_installer.sh` (fetched from `dns_feature_branch`, default `main`; in air-gapped mode
  extracted from the bundled `technitium-save.tar.gz`, whose top-level sentinel makes the installer pick its
  offline path by itself). Pre-flight: refuses a host where `rke2-server`/`rke2-agent` is active unless
  `DNS_ALLOW_COLOCATION=true` (Technitium takes over `:53` and the host resolver, which breaks in-cluster DNS
  for the lab names and collides with systemd-resolved's stub); fails when anything other than
  systemd-resolved/Technitium already holds port 53; warns on the default `changeme` password; validates
  `DNS_ZONE` and a user-supplied `DNS_ZONES_TEMPLATE`. `-registry`, `push` and `-tls-san` are rejected (no
  images, no cluster role). Records `DNS_SERVER_INSTALLED` / `DNS_WEB_PORT` / `DNS_ZONES_FILE` in
  `/var/lib/ap-tools/state.env` and prints the console URL, the seeded records and the
  `config static-ip … -dns <ip>` next step.
- **Record seeding.** ap-tools writes the installer's zone template (`ap-install/ap-utilities/dns/zones.txt`)
  from `DNS_ZONE` (default `BASE_DOMAIN`), `DNS_DAP_FQDN` (default `HOST_FQDN`) + `DNS_DAP_IP` (the four
  `portal.` / `orchestrator.` / `mtls-orchestrator.` / `mtls-recovery-orchestrator.` names and the bare host
  name), `DNS_DAP_NODE_IPS` (multi-node: the bare cluster/`-tls-san` name round-robins over the node IPs),
  `DNS_REGISTRY_IP` (`HARBOR_COMMON_NAME`), `DNS_SWFS_IP` (the four `SWFS_*_FQDN` names), `DNS_FDO_RV_IP`
  (`rv.dell.fdo`) and `DNS_EXTRA_RECORDS` (`name=ip,…`). Every seeded name must sit under `DNS_ZONE` (clear
  error otherwise); IPs are validated; duplicates are collapsed. The template is regenerated on every run and
  the installer converges each name's A-record set to it, so a changed IP replaces the stale record.
  `DNS_ZONES_TEMPLATE=<file>` replaces the generated template with your own.
- **Pass-through configuration** (`DNS_`-prefixed where the installer's name is generic): `DNS_ADMIN_PASSWORD`
  (defaults to `SWFS_HARBOR_PASS`), `DNS_ADMIN_CURRENT_PASSWORD`, `DNS_WEB_PORT`, `DNS_ENABLE_HTTPS` /
  `DNS_HTTPS_PORT`, `DNS_FORWARDERS` / `DNS_FORWARDER_PROTOCOL`, `DNS_ENABLE_DNSSEC` / `DNSSEC_ALGORITHM` /
  `DNSSEC_CURVE`, `DNS_RECORD_TTL`, `DNS_DISABLE_SYSTEMD_RESOLVED`, `DNS_ENABLE_DHCP` + the `DHCP_*` set
  (forwarded as-is, not exercised by ap-tools' own tests), `DNS_REMOVE_DOTNET`. The password is passed as a
  quoted prefix assignment and never printed.
- **`uninstall dns-server [--purge-cache]`.** Destructive (`yes-destroy` / `AP_ASSUME_YES=true`); delegates to
  `technitium_dns_installer.sh uninstall`, forwarding only user-set `PURGE_DATA` (shared with Harbor) and
  `DNS_REMOVE_DOTNET` so the installer's own recorded state governs the resolver/firewall restore. A no-op on
  a never-installed host. Clears the `DNS_*` state keys.
- **`offline-prep` bundles Technitium.** New `download_dns_server` runs `technitium_dns_installer.sh save`
  (DNS package + ASP.NET Core runtime + `libicu` via install-packages + the installer, ~66 MB) into
  `ap-utilities/dns/`, unconditionally like Harbor/SeaweedFS. The bundle is OS-family/arch specific like the
  rest of the archive.
- **Licensing.** The archive's `LICENSES/THIRD_PARTY_NOTICES.txt` and `WRITTEN_OFFER.txt` now cover Technitium
  DNS Server (**GPL-3.0**, redistributed in binary form), plus the .NET runtime (MIT) and libicu; `NOTICE` and
  the README credits list them.
- **Docs / agents.** README (Quick Start "No DNS server?" pointer, CLI tables, valid combinations, a
  `DNS Server (Technitium)` variable section, usage examples for single- and multi-node, a DNS host sizing
  table, DNS Records + Co-location notes, references/credits), `inputs.env.example`, `AGENTS.md`, the bundled
  `deploy-dell-ap` skill (phase table, hard prerequisites, Phase C step 0, intake §3, `reference/commands.md`,
  `reference/dns-and-certs.md` "Option B", `reference/prerequisites.md`, `dap-deploy-template.env`) and the
  Devin playbook.

### Changed
- `create_working_dir` adds `ap-utilities/dns`; `usage` / `display` text, the install/uninstall type
  validators and the main-flow component switch list `dns-server`; `firewalld_selinux_preflight` has a
  `dns-server` case; `dns_feature_branch` joins the sub-installer branch overrides.

### Validation (2026-09-11, fresh Ubuntu 24.04 clones of template 119: `dns-smk1` .214 online, `dns-smk2` .215 air-gap;
runbook `chubtoad-automation/runbook/2026-09-11-dns-server-component.md`)
- Generator unit test (6 cases incl. dedupe, apex + round-robin, the three error paths); `bash -n` + shellcheck clean.
- Negatives on .214: `push`/`-registry`/`-tls-san` combos → exit 1; uninstall on a clean host → exit 0 no-op; a
  dummy active `rke2-server.service` → exit 1 with the co-location message and nothing installed; a python
  process bound to `:53` → exit 1 naming it.
- Seeded online install (`DNS_DAP_IP`, `DNS_REGISTRY_IP`, `DNS_SWFS_IP`, `DNS_FDO_RV_IP`, forwarders, extras incl.
  a wildcard): exit 0 in ~1.5 min; zones `dev.test` + `dell.fdo`, 13 A records; every name answered from the new
  server with the exact input IP (`dig`), public names forwarded; resolver commandeered; console login only with the
  new password; state keys recorded; 0 password occurrences in any log/template/state file.
- Re-run with identical inputs → exit 0, all records `(exists)`; `DNS_DAP_IP` changed + `DNS_DAP_NODE_IPS` of two IPs →
  the four DAP names replaced (stale A removed), bare name round-robins over both; password rotation via
  `DNS_ADMIN_CURRENT_PASSWORD` works (old password rejected afterwards).
- `uninstall dns-server`: exit 0, server/unit/user gone, `/etc/dns` + `/opt/dotnet` kept, `DNS_*` state keys cleared,
  second run a no-op; `PURGE_DATA=true DNS_REMOVE_DOTNET=true` removes `/etc/dns`, `/opt/dotnet`, `/usr/bin/dotnet`.
  A reinstall after a keep-data uninstall must reuse the stored password (documented).
- Pass-throughs: `DNS_ZONES_TEMPLATE` (user file wins, seeding inputs ignored with a NOTE), `DNS_WEB_PORT=8053`,
  `DNS_ENABLE_HTTPS=true` + `DNS_HTTPS_PORT` — see the runbook.
- Found + fixed in the sibling repo (technitium-dns-installer v1.2.1, branch `fix/uninstall-resolved-stub-restore`,
  owner review): after online re-runs upstream `install.sh` overwrites its resolv.conf backup, so `uninstall`
  pinned public nameservers on a systemd-resolved host; it now re-links the resolved stub. Air-gap installs are
  unaffected. Merge that fix before this feature (ap-tools fetches technitium from `main`).
- Air-gap (.215): `offline-prep` (8.5 GB archive incl. the 68 MB Technitium bundle; `LICENSES/` names Technitium), then
  with the default route removed and the tree re-extracted from the archive alone: `install dns-server` took the
  installer's offline path (`Air-gap bundle detected`, libicu from the offline package set, no downloads), all seeded
  names answered from the host, login ok; purge uninstall restored the stub resolver and cleared the state keys.
- dep-validator: SAFE TO MERGE, no blockers; its four non-blocking points were fixed before this entry (bare `*.label`
  extras accepted and documented correctly, relative `DNS_ZONES_TEMPLATE` made absolute in the preflight, glob-safe
  list splitting, `pipefail`-safe outputs). Note: `offline-prep` now also needs `download.technitium.com` and `dot.net`
  reachable, since the DNS bundle is always included.

## 2026-09-10 — `install ddpc-bundle`: Dell Distributed Private Cloud add-on staging (feature/ddpc-bundle)

Adds a stage-then-run flow for Dell's **Distributed Private Cloud (DDPC) 4.3.0.0** add-on, which installs
*into* a running DAP 2.1.1.0 orchestrator (same cluster, same namespace). It mirrors `install ap-bundle`:
ap-tools pre-checks, downloads and extracts, then hands the operator a ready-to-run
`ddpc-install-upgrade-cmd.txt`; it never runs Dell's installer itself.

### Added
- **`install ddpc-bundle [-registry <host:port> <user> <pass>]`.** Pre-flight, all before the ~6 GB
  download: Kubernetes API answers and every node is `Ready`; the `native-edge-orchestrator` and
  `dap-portal` helm releases are `deployed`; the orchestrator app version equals
  `DDPC_REQUIRED_DAP_VERSION` (default `2.1.1.0`, exact match, `any` disables); no pod in
  `kube-system` / portal / orchestrator namespaces is outside `Running`/`Completed`; `ORCHESTRATOR_FQDN`
  is a host the orchestrator ingress actually serves (it becomes DDPC's `DAPO_HOST`); an existing DDPC
  release is reported (re-runs are safe), leftover eo-chart NE-service pods are refused; the registry
  answers on `/v2/` (credentials verified with `-registry`, CA trust verified without); the cluster has
  `DDPC_REQUIRED_CPU_HEADROOM` / `DDPC_REQUIRED_MEM_HEADROOM_GB` of **unrequested** capacity and
  `DDPC_REQUIRED_DISK_GB` free under `ap-install/`; NTP state is reported. Dell's own DDPC installer has
  no resource gate, and a node that passed the DAP gate can still be fully committed by DAP, hence the
  headroom model.
- **`-registry` is optional for DDPC.** Given, ap-tools reuses the ap-bundle CA-trust/docker path and
  emits explicit credentials (DDPC creates its own `distpvtcloud-docker-secret`). Omitted, ap-tools
  decodes the orchestrator's `docker-secret` for the registry URL and emits a credential-free command so
  Dell's installer reuses that secret. A mismatch between the two registries is warned about.
- **Every parameter of DDPC's `install-upgrade.sh` is exposed:** `DDPC_BUNDLE_URL`,
  `DDPC_SKIP_IMAGES_LOADER` (defaults to `SKIP_IMAGES_LOADER`), `DDPC_IMAGE_LOADER_PARALLEL_JOBS`,
  `DDPC_IMAGE_LOADER_MAX_RETRIES` and `DDPC_LOG_LEVEL` (env-only in Dell's script, emitted as an `env`
  prefix), `DDPC_INSTALL_TYPE`, `DDPC_INSTALL_TIMEOUT`; `DAPO_HOST`/`NAMESPACE` come from
  `ORCHESTRATOR_FQDN`/`ORCHESTRATOR_NAMESPACE`. Plus `DOWNLOAD_DDPC_BUNDLE` for `offline-prep` and the
  three pre-flight gates above. All `${VAR:-default}` and in `inputs.env.example`.
- **`uninstall ddpc-bundle [--purge-cache]`** — staging only (the `ddpc-bundle/` tree, the cmd file and
  the `DDPC_*` state keys; the zip is kept), plus the registry CA / `certs.d` entry **only when**
  `install ddpc-bundle -registry` targeted a registry other than DAP's own (recorded under
  `DDPC_REG_*` state keys; the ap-bundle `AP_REG_*` keys stay authoritative for DAP's registry). It
  prints Dell's in-cluster removal (`helm uninstall dell-distributed-private-cloud` + configmap/secret
  cleanup) and deliberately does not run it.
- **Idempotent re-runs:** an already-downloaded zip, an already-extracted tree, an unchanged registry
  CA and a running docker are all skipped; only the command file is regenerated. Running the generated
  command twice is safe too — Dell's installer skips a same-version install, retries a failed one and
  records a `distpvtcloud-image-push-status` configmap so the image push is not repeated.
- Skill package: SKILL.md phase 7 + add-on section, intake 4c, `reference/commands.md`,
  `prerequisites.md`, `troubleshooting.md` #18/#19, `registry.md` (DDPC images + authenticate before
  judging a Harbor project missing), `dap-deploy-template.env`, and a read-only **`preflight.sh --ddpc`**
  mode that runs the same in-cluster readiness checks. `AGENTS.md` and the Devin playbook mirror it.

### Changed
- The DAP and DDPC bundle fetch/extract now share `download_dell_bundle` (browser UA on `dl.dell.com`,
  `.partial` + resume, explicit air-gap error when the zip is absent) and `extract_dell_bundle` (signed
  outer zip → inner bundle zip). `install ap-bundle` behaviour is unchanged apart from generalised
  wording. The NTP check moved to a shared `ntp_preflight_check`.
- The generated command blocks (ap-bundle **and** ddpc-bundle) now escape `"`, `$`, `\` and backtick in
  the emitted registry password; such a password previously produced an unparsable block. `mask_secret`
  matches the password literally (quoted pattern) in both its raw and escaped form, so passwords with
  shell or glob characters are masked on stdout too.
- `inputs.env.example` had a stale 2.0.0.0 `AP_BUNDLE_URL` example; it now shows the 2.1.1.0 default.

### Validation (2026-09-10, single-node dap-aio, Ubuntu 24.04, DAP 2.1.1.0, Harbor registry)
- **Manual DDPC install** with the exact parameters the tool generates: exit 0 in **9m00s** (checksum ~50 s,
  docker load ~2.5 min, 19 pushes ~50 s, helm ~4.5 min). 10 deployments `1/1`, all jobs complete, 0 PVCs,
  DAP untouched; node disk +23 GB; a same-version re-run exits 0 in 0.3 s.
- **Tool on the live host:** `install ddpc-bundle -registry …` (existing release noted, no restarts,
  no re-extraction), the generated block (skip), reuse mode without `-registry` (credential-free block,
  skip), `uninstall ddpc-bundle` (staging only, release untouched, second run a no-op), re-stage, and four
  negative pre-checks (wrong DAP version, unresolvable registry, bad password, orchestrator FQDN not served)
  — all as designed.
- **Fresh end-to-end** on a re-cloned VM: `install rke2` → `install ap-bundle` → DAP install →
  `install ddpc-bundle -registry …` (2.5 min) → generated DDPC install (**6m49s**, loader on) → verify →
  idempotent re-run → reuse mode → negatives → uninstall/re-stage; 0 unhealthy pods at the end.
- dep-validator: **SAFE TO MERGE** (no sub-installer contract drift; `install ap-bundle` behaviour-preserving).
  It caught the masking regression fixed above.

## 2026-09-09 — Static-analysis pass: shellcheck clean, plus one latent uninstall bug

`ap-tools` is now clean under `shellcheck -S warning` (was 10 findings). Mostly hygiene, but one
finding turned out to be a real defect.

### Fixed
- **`uninstall ap-bundle` could leave the registry CA in the system trust store.** `AP_REG_FQDN` is
  recorded early (during registry/docker setup) while `AP_REG_CA_PATH` is only recorded after the
  bundle download — so an `install ap-bundle` that failed during that download left state holding the
  FQDN but no CA path. `uninstall ap-bundle` read the recorded FQDN into a variable, **never used it**,
  and instead required the operator to re-pass `-registry` before it would look for the CA. It now
  prefers the recorded FQDN and falls back to the `-registry` argument. Same class of bug the
  `/opt/harbor/.install-env` work fixed in `install_harbor.sh`; this instance was missed.
  The `certs.d` derivation is now guarded so it can only be built from a non-empty `REGISTRY_INFO` —
  an empty value would have produced the bare `/etc/docker/certs.d/` directory, which the existing
  `-d` test would have accepted and removed wholesale.
- **`runtime_outputs` no longer prints an empty join token.** `local join_token=$(cat …)` masked the
  read's exit status behind `local`'s own; declaring and assigning separately restores `errexit`, so an
  unreadable `node-token` fails the run instead of silently emitting a blank token.
- Two single-iteration `for` loops over a quoted path (the air-gap SeaweedFS and Harbor archive
  extractions) replaced with direct `tar` calls — the same shape as the quoted-glob air-gap bug fixed
  in `seaweedfs-installer`, though here the paths are literal so behaviour is unchanged.
- Quoting fixes with no behavioural change: `$(basename …)` in the support-log-collector download, and
  the right-hand side of `[[ $ORCHESTRATOR_FQDN == "$MGMT_IP" ]]` (unquoted, it was glob-matched).

## 2026-09-09 — DAP 2.1.1.0 support: resource requirements, bundle default, image-loader threads

Validated end-to-end against a live DAP **2.1.1.0** single-node install. No change was needed to make
2.1.1.0 work — all parameters `ap-tools` emits are still valid — but its resource requirements and one
new tunable are now reflected here.

### Changed
- **`AP_BUNDLE_URL` now defaults to DAP 2.1.1.0** (was 2.0.0.0). The `dl.dell.com` `FOLDER…` path
  changes with every release, so overriding this means replacing the whole URL, not just the version.
- **Resource requirements raised for DAP 2.1.1.0** — single-node is now **18 vCPU / 36 GB / 1 TB**:
  - `ap-tools` cluster gate (measured against **allocatable** capacity during `install ap-bundle`):
    `REQUIRED_CPU` 16 → **18**, `REQUIRED_MEM_GB` 32 → **34**, `REQUIRED_STORAGE_GB` 500 → **850**.
  - `skills/deploy-dell-ap/scripts/preflight.sh` (measured on the bare host): `MIN_CPU` 16 → **18**,
    `MIN_RAM_GB` 34 → **36**, `MIN_DISK_GB` 500 → **850**.
  - The memory pair stays 2 GB apart on purpose: RKE2 and the OS reserve ~2 GB, so a host
    **provisioned** with 36 GB reports ~34 GB **allocatable**. Provision 36, the gate checks 34.
  - **The storage change is the important one.** DAP 2.1.1.0's own `pre_install_check` enforces
    `REQUIRED_DISK_SPACE=850Gi` against each node's allocatable *ephemeral-storage*. At the old 500 GB
    floor a host passed both of our checks and then failed Dell's partway through the install.
    Allocatable sits below the raw filesystem size, so **1 TB is the safe provisioning target** —
    exactly 850 GB will not reliably pass.

### Added
- **`IMAGE_LOADER_THREAD_COUNT`** (default `5`, Dell's own default; maximum 20) — parallel image-push
  threads, now passed through to `install-upgrade.sh`. The image push dominates install time
  (~35 of 56 minutes in the validated run), so this is the most direct lever on total duration. Values
  outside 1–20 are rejected by Dell's installer, which already validates the range.
  **Not new in 2.1.1.0** — DAP 2.0.0.0 accepts it too; `ap-tools` simply never passed it. Pinning
  `AP_BUNDLE_URL` back to 2.0.0.0 therefore stays safe.

### Documentation
- The bundled `skills/deploy-dell-ap/` package and the `devin/` playbook were swept to the same figures,
  so the skill no longer tells an operator to size a host that its own `preflight.sh` rejects:
  `reference/prerequisites.md`, `SKILL.md`, `intake.md`, `reference/troubleshooting.md`,
  `dap-deploy-template.env` and `devin/deploy-dell-ap.devin.md`.
- **Multi-node storage:** `ap-tools` sums allocatable capacity across the cluster, but Dell applies the
  850 GB ephemeral-storage requirement **per node** — so the per-node disk figure is now 850 GB+
  everywhere. A 3-node cluster of 500 GB nodes passes our gate and fails Dell's. Multi-node CPU/RAM
  figures are unchanged: they predate 2.1.1.0 and have not been re-validated against it.

## 2026-09-09 — Idempotence release (feature/idempotence-phase2)

`ap-tools` gains the three capabilities it was missing — **uninstall**, **host-config
helpers**, and an **inputs file** — on top of a suite-wide idempotence pass. Installs are now
re-runnable, every user-facing variable is overridable at runtime, and `ap-tools` owns its
add-on container images end-to-end for air-gap.

### Added
- **`uninstall <component> [--purge-cache]`** — mirrors `install` for `rke2`, `harbor`,
  `swfs`, `velero`, `monitoring` and `ap-bundle`. Each flow reverts **only** what ap-tools and
  its sub-installers changed, driven by recorded state in `/var/lib/ap-tools/state.env`
  (mode 0600: prior multipathd/iscsid enablement, whether docker and `/etc/multipath.conf`
  pre-existed, and what ap-tools itself installed — helm, k9s, longhornctl, the registry CA,
  the sysctl file, NTP config). Sub-installers keep their own state files for the same
  purpose; only explicitly-set environment values are forwarded, so each tool's recorded state
  stays authoritative.
  Destructive targets (`rke2`, `harbor`, `swfs`) require typing `yes-destroy`; set
  `AP_ASSUME_YES=true` for automation. `--purge-cache` additionally deletes the ~20 GB
  `$PWD/ap-install` working cache.
  Note: `uninstall ap-bundle` removes the DAP **staging** (registry CA, `certs.d` entry,
  extracted `bundle/` tree, `ap-install-upgrade-cmd.txt`) — DAP itself runs in the cluster and
  goes away with `uninstall rke2` or Dell's own procedure.
- **`config hostname <fqdn>`** — sets the hostname via `hostnamectl` and reconciles a
  marker-tagged `/etc/hosts` entry (the `127.0.1.1` line on Debian-family;
  `<MGMT_IP> <fqdn> <short>` on Rocky/RHEL/Leap). Validates the FQDN and **refuses to run
  while an RKE2 service is active**.
- **`config static-ip …`** — **generate-and-validate by default**: it prints exactly what
  would be applied (netplan YAML on Ubuntu/Debian, `nmcli` commands on Rocky/RHEL/Leap 16) and
  changes nothing. `--apply` activates it behind an auto-revert: `netplan try --timeout 120`
  on Debian-family, or a 120 s NetworkManager auto-revert confirmed with
  `config static-ip commit`. It refuses to modify the interface carrying your SSH session
  unless `--force-ssh-interface` is given.
- **`inputs.env` support** — an optional sourced inputs file with
  `CLI env > inputs.env > defaults` precedence, plus an `inputs.env.example` template. Every
  hardcoded user-facing variable was converted to `${VAR:-default}`, so runtime overrides work
  across the board.
- **`NTP_SERVERS` and `RKE2_RECONFIGURE`** forwarded to `rke2_installer.sh`; NTP configuration
  itself now lives in the RKE2 installer.

### Fixed
- **Re-run / reconcile.** `install rke2` on an already-running node reconciles instead of
  hard-failing: unchanged config no-ops, changed config applies with `RKE2_RECONFIGURE=true`,
  and add-ons re-apply via `helm upgrade --install`. This closes the "interrupted install can
  only be recovered from a clean host" gap.
- **Truthful exit codes** — `run_debug` corrected under `errexit`, `on_exit` failure
  reporting added, the dead `cleanup()` removed.
- **Preflight math fixed.** `ap_preflight_checks` printed meaningless CPU/memory values
  (e.g. `Memory: 1.5e17 GB`); the allocatable-resource conversion now prints real numbers.
  DNS checks use `getent`, the management-interface match is exact, the `HOST_FQDN` default is
  FQDN-safe, and an `OS_ID` guard was added.
- **`REG_PASS` masked** in all stdout (runtime-argument display, parsed args, command-file
  echo), and `ap-install-upgrade-cmd.txt` is written mode 0600.
- **iscsid is enabled at boot**, the air-gap docker-load glob works, ap-bundle restarts are
  conditional, a multipath drop-in is written, ap-bundle prerequisites are checked, and there
  is a firewalld/SELinux preflight.
- **ap-tools owns its add-on images end-to-end** — regenerated image list, its own save
  archive, its own push, and its own air-gap staging.
- **Bundle download hardened** — `curl` with resume, an atomic sentinel-safe offline archive,
  absolute-path-safe offline-prep, and a guarded `LICENSES` removal. The install-time
  `bundle/` extraction is excluded from the offline archive.
- **One `fetch_subtool`** for every sub-installer (`curl -f`, atomic, branch-aware cache),
  consolidating the duplicated k9s / support-tool / longhorn-map fetch code.
- **`HELM_VERSION` default 4.0.1** (matching `rke2-installer`), still overridable, and helm,
  k9s and longhornctl now install to `/usr/local/bin` as documented.
- README corrections: the RAM requirement is **34 GB** (the `install ap-bundle` preflight
  needs 32 GB *allocatable*, and RKE2 + the OS reserve ~2 GB, so a host provisioned with
  exactly 32 GB fails), plus version-table drift and `regsitry` example typos.

### Unchanged
- Existing CLI surface (`install <component>`, `upgrade rke2`, `join server|agent`,
  `offline-prep`, `push`, and the `-tls-san` / `-registry` flags) and every existing
  variable name are unchanged — `inputs.env` is additive and current
  environment-variable workflows keep working unmodified.
- `ap-tools` is now tracked executable (mode 755).
