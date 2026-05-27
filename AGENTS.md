# AGENTS.md — automation-platform-tools

This repository provides **`ap-tools`**, a script that deploys Dell Automation Platform (DAP)
on-premise — an RKE2 Kubernetes cluster, an optional Harbor registry, and the DAP bundle — on Linux
host(s) you provide.

## Deploying DAP with an agent
To install / stand up Dell Automation Platform, **follow the skill at
[`skills/deploy-dell-ap/SKILL.md`](skills/deploy-dell-ap/SKILL.md)**. It interviews the user for
topology, host/SSH access, DNS, registry, and identity, then installs in the correct order. Do not
improvise the sequence — read the skill and its `reference/` files first. (Devin users: an equivalent
Playbook is at [`devin/deploy-dell-ap.devin.md`](devin/deploy-dell-ap.devin.md).)

## Conventions
- `ap-tools` runs as **root on the target host**. From a remote machine, SSH in to run each step.
- Install components in order: `install rke2` → (`install harbor`) → `install ap-bundle` → run the
  generated `install-upgrade.sh`. `install ap-bundle` stages the bundle but does **not** deploy DAP by
  itself.
- Exit code 0 is not proof of success — verify nodes, pods, and the portal after install.
- Never commit secrets. Pass registry and SSH credentials at run time, not in files.
- The companion installers (`rke2-installer`, `harbor-registry-installer`, `seaweedfs-installer`,
  `images-pull-push`, `install-packages`) are separate Chubtoad5 repositories that `ap-tools` fetches
  and calls at runtime.

## Repo map
- `ap-tools` — the orchestrator script (the thing you run).
- `skills/deploy-dell-ap/` — portable deployment skill for AI agents (documentation + a preflight
  script; it does not change the tool).
- `devin/deploy-dell-ap.devin.md` — the same procedure as a Devin Playbook.
- `README.md` — human documentation, including the single-node Quick Start.
