# Changelog — automation-platform-tools

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
  the `DDPC_*` state keys; the zip is kept). It prints Dell's in-cluster removal (`helm uninstall
  dell-distributed-private-cloud` + configmap/secret cleanup) and deliberately does not run it.
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
  the emitted registry password; such a password previously produced an unparsable block.
- `inputs.env.example` had a stale 2.0.0.0 `AP_BUNDLE_URL` example; it now shows the 2.1.1.0 default.

### Validation
- _Manual DDPC install and fresh end-to-end smoke recorded in the chubtoad-automation project runbook
  `runbook/2026-09-10-ddpc-bundle.md` (results to be appended)._

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
