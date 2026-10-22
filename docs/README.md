# Documentation

Step-by-step guides for people who want to install Dell Automation Platform (DAP) **by hand** instead of
with the `ap-tools` script. Each guide does manually what the script does automatically, using the same
versions and settings, so a host built from a guide matches a host built by `ap-tools`.

For the automated path, see the [Quick Start in the main README](../README.md#quick-start-single-node).

> These guides are written for humans. AI agents deploying DAP should follow
> [`skills/deploy-dell-ap/SKILL.md`](../skills/deploy-dell-ap/SKILL.md) instead.

## DAP installation guides (`dap-install/`)

| Guide | OS | Network | Topology | Covers | Status |
|:--|:--|:--|:--|:--|:--|
| [Manual Install: DAP + DDPC on Ubuntu 24.04](dap-install/ubuntu-dap-ddpc-manual-install.md) | Ubuntu 24.04 | Connected | Single-node | RKE2, MetalLB, HAProxy, Longhorn, DAP 2.1.1.0, DDPC 4.3.0.0 | Available |
| Harbor registry install | — | — | — | A private registry for the DAP images | Planned |
| Air-gapped variant | — | Air-gapped | — | Installing from bundles with no internet access | Planned |
| RHEL / SLES variants | RHEL 9, SLES 15 | — | — | The same steps for other supported distributions | Planned |
| Multi-node | — | — | 3 nodes | Joining nodes, an ingress VIP, replicated storage | Planned |
