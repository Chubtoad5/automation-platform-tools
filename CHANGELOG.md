# Changelog — automation-platform-tools

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
