# Automation Platform Tools
This is an unofficial pre-requisite tool designed for use with Dell Automation Platform on-premise bundle installation. 

## Preface
This repository is not associated with Dell Technologies and the script is not officially supported. The tooling this script provides is based off system requirements from the official Dell Automation Platform documentation found on https://www.dell.com/support and leverages opensource tools. This script should not be used for a production environment.

## Main Feature Functionality
The main purpose of this script is to prepare a single-node kubernetes environment for deploying Automation Platform Portal and Orchestrator.

- **RKE2** - Installs a single-node rke2 kubernetes instance with all prerequisite host OS packages and configurations required for Automation Platform, including helm, zip, jq, and sysctl parameters.
- **SUPPORTING SERVICES** - Installs additional kubernetes services used by Automation Platform, including a CNI, Longhorn Storage Provider, MetalLB Loadbalancer, and HAProxy Tech kubernetes ingress.
- **BUNDLE** - Downloads, extracts, and prepares the Automation Platform bundle, providing the install command based off defined variables.
- **AIR-GAPPED** - Option to prepare an offline/air-gapped bundle, which contains all the necessary binaries for deploying Automation Platform into an isoloated enviroment where no internet access is possible.
- **LOCAL REGISTRY** - Supports using a local named registry for kubernetes containers. The script is capable of first pulling the containers from the internet and push in to the defined registry, then installing RKE2 which will pull from the local registry.

## Alternative Deployment Options
Instead of installing kubernetes, this tool supports installing common infrastructure applications that Automation Platform leverages.

- **REGISTRY** - Install a Harbor OCI registry using self-signed certificates, typically used for pushing the Automation Platform container images during bundle installation.
- **FILE SERVER** - Install an NGINX static file server, typically used for providing a simple file/object repository for storing blueprint binaries and images.
- **JOIN** - Join the host to an existing cluster as a server or agent node.  
**NOTES ON USING JOIN**
- - By default, `install rke2` installs as a single-node cluster and sets longhorn replica count to `1`. If planning a multi-node deployment, be sure to set `CLUSTER_TYPE=multi-node`.
- - The `join` command should only be used against an existing RKE2 cluster of the same version. It is recommened to only join a cluster that was created by this script to avoid potential installation configuration issues.
- - If the cluster was initially created with `-registry`, then `-registry` must be used with `join` to ensure all nodes pull containers from the registry.
- - If the cluster was created with `-tls-san`, then each additional server joined must also use `-tls-san`.

## Host Prerequisites

### Operating System Support
This script only supports x86 based linux operating systems. OS pre-checks verify the OS_ID is one of: `ubuntu, debian, rhel, centos, rocky, almalinux, fedora, sles, or opensuse-leap`. However, this script is mainly tested with the following three operating systems:

- Ubuntu Server LTS 22.04 or higher
- RedHat Enterprise Linux (RHEL) 9.2 or higher
- SLES 15 SP7  

### Host Resources

Automation Platform bundle requires:
- 16 CPU
- 32 GB Ram
- 1 TB SSD  
**NOTE:** CPU and Memory requirements are based off the avaiable resources as seen from the kubernetes cluster (i.e. `kubectl describe node <node-name>`).

NGINX recommendation:  
- 2-4 CPU
- 4-8 GB Ram
- Enough disk for the image/binary size of the Automation Platform application use case (blueprints, vms, etc)

Harbor recommendation:  
- 4 CPU
- 8 GB Ram
- 500 GB SSD or larger

## Network Requirements
In general, static IP or DHCP reservation and DNS A records are highly recommened for all deployment options.  

### IP Assignment
- The Kubernetes used for Automation Platform REQUIRES a static IP due to the configuration of MetalLB, which defines a LoadBalancer IP at time of RKE2 installation using the host's primary management interface.
- NGINX does not require a static IP but it is highly recommended.
- Harbor does not require a static IP but it is highly recommended.  

### Hostname considerations
Kubernetes strictly enforces `DNS-1123 subdomain format` which is derived from `RFC 1123`. The standard requires all node names to be lower-case and follow the regex pattern: `[a-z0-9]([-a-z0-9]*[a-z0-9])?`. RKE2 uses the hostname as the node name, therefore make sure the hostname matches this standard before installation of RKE2.  

### DNS Assignment
DNS A records are highly recommened for Harbor and NGINX, and required for Automation Platform. As of `Automation Platform version 1.0.0.0` there are three required DNS records and one optional record depending on the device onboarding method.  

Bellow is an example DNS A record schema for FQDN:IP mapping:

| Service             | FQDN                          | IP Address                          |
|:--------------------|:------------------------------|:------------------------------------|
| Harbor              | registry.mydomain.lab         | 192.168.50.20                       |
| NGINX               | artifacts.mydomain.lab        | 192.168.50.25                       |
| RKE2 Kubernetes     | myk8snode.mydomain.lab        | 192.168.50.30                       |
| RKE2 Kubernetes     | myk8scluster.mydomain.lab     | 192.168.50.30, 192.168.50.31, 192.168.50.32, etc... |
| Automation Platform | portal.mydomain.lab           | 192.168.50.35                       |
| Automation Platform | orchestrator.mydomain.lab     | 192.168.50.35                       |
| Automation Platform | mtls-orchestrator.mydomain.lab| 192.168.50.35                       |
| Automation Platform | rv.dell.fdo                   | 192.168.50.35                       |

**IMPORTANT NOTES ON DNS**   
- The `myk8scluster` entry is only needed if using `tls-san` mode for multi-node k8s, each server node would resolve to the cluster FQDN.
- The `mtls-` prefix is a hard requirement for Automation Platform Orchestrator used for device mTLS authentication.
- The `rv.dell.fdo` record is only required if Global Rendezvous is not being used (i.e. air-gapped environment) for FDO onboarding.
- Using a DNS zone called ```local.edge``` is not recommened per Dell Technologies guidance.
- Using a DNS zone of `*.local` is not recommened per `RFC 6762 Multicast DNS (mDNS)` standards.  

### Local Registry
When using a local registry, all required containers must exist on the registry, or the registry must act as a mirror/passthrough. When using the `push` functionality, the script assumes the proper project path exists on the defined registry. The script leverages Docker engine and cli to pull/push containers. If Docker is not installed, the script will automatically attempt to install it.  

The following project paths must be pre-configured on the local registry when `push` is specified:  
- `/rancher`-  Rancher RKE2 project, pulled from docker.io
- `/haproxytech` - HAProxy Tech kubernetes-ingress, pulled from docker.io
- `/longhornio` - Longhorn storage provider, pulled from docker.io
- `/metallb` - MetalLB loadbalancer, pulled from quay.io
- `/frrouting` - Part of MetallB project, pulled from quay.io
- `/e2e-test-images` - Used when `INSTALL_DNS_utility=true`, official kubernetes.io dns utility  

When installing Dell Automation Platform Portal & Orchestrator, the installation bundle pushes all container images from the bundle to the local registry. Before installing, ensure the local registry a dedicated project pre-created and the USER DEFINED variable `REGISTRY_PROJECT_NAME` is updated.  

## Usage

1. Download the `ap-tools` script or clone this repository and make the file executable.  
```
git clone https://github.com/Chubtoad5/automation-platform-tools.git
cd automation-platform-tools
chmod +x ap-tools
```
2. Optional, edit the default `USER DEFINED` variables to match the environment needs.  
```
vi ap-tools
```
3. Run the script as sudo/root supplying the `[command] [args]`.  
```
sudo ./ap-tools install rke2
```

### One-liner for RKE2 install using default variables
```
git clone https://github.com/Chubtoad5/automation-platform-tools.git && cd automation-platform-tools && chmod +x ap-tools && sudo ./ap-tools install rke2
```

### Syntax
```
Usage: ./ap-tools [install rke2|ap-bundle|harbor|nginx] [offline-prep] [push] [join server|agent [server-fqdn] [join-token-string]] [-tls-san [server-fqdn-ip]] [-registry [registry:port username password]]

Commands:
  install      : Installs specified component and any dependencies.
                 For air-gapped install, ap-offline.tar.gz file must be in the same directory as script.
                  [rke2]       Installs rke2 as a server.
                  [ap-bundle] Extracts the Dell Automation Platform install bundle and outputs the install command. 
                               Must be used with [-registry].
                  [harbor]     Installs the harbor registry.
                  [nginx]      Installs an nginx static file server.
  offline-prep : Creates an offline tar package which contains all dependencies for an air-gapped installation.
                 Cannot be used with [install] [push] [join].
  push         : Pushes all kubernetes and utility container images to the specified registry. 
                 [-registry] must be specified. Does not push Dell Automation Platform images.
  join         : Joins the host to an existing cluster as a [server] or [agent]. 
                 [server-fqdn] and [join-token-string] must be specified.
  -tls-san     : When provided,adds specified FQDN to rke2 tls-san configuration for multi-node setup. 
                 Used with [install rke2] or [join server]. [server-fqdn-ip] must be a valid IP or FQDN.
  -registry    : Used with [install rke2], [install ap-bundle], and [push] to provide a valid registry and credentials.
```

### Examples

#### Install RKE2 with default settings

```
sudo ./ap-tools install rke2
```

#### Install RKE2 and configure an additional TLS-SAN (typically for multi-node clusters)
```
sudo ./ap-tools install rke2 -tls-san rke2-cluster.mydomain.lab
```

#### Install RKE2 and use a local registry
```
sudo ./ap-tools install rke2 -registry myregistry.lab:443 username password
```

#### Push container images to a local registry, then install RKE2 and configure an additional TLS-SAN
```
sudo ./ap-tools install rke2 push -registry myregistry.lab:443 username password -tls-san rke2-cluster.mydomain.lab
```

#### Join to an existing RKE2 cluster as a server
```
sudo ./ap-tools join server myk8snode.mydomain.lab <token_string> 
```

#### Join to an existing RKE2 cluster as a server using a local registry and additional TLS-SAN
```
sudo ./ap-tools join server rke2-cluster.mydomain.com <token_string> -registry registry.mydomain.lab username password -tls-san rke2-cluster.mydomain.lab
```

#### Join to an existing RKE2 cluster as an agent 
```
sudo ./ap-tools join agent myk8snode.mydomain.lab <token_string> 
```

#### Only push RKE2 and Service containers to a registry
```
sudo ./ap-tools push -registry myregistry.lab:8443 username password
```

#### Install Harbor regisrtry
```
sudo ./ap-tools install harbor
```

#### Install NGINX file server
```
sudo ./ap-tools install nginx
```

#### Install Automation Platform Bundle
```
sudo ./ap-tools install ap-bundle -registry myregistry.lab:443 username password
```

#### Prepare an offline archive for air-gapped environment
```
sudo ./ap-tools offline-prep
```
#### Use the offline archive to install RKE2
```
tar xzf ap-offline.tar.gz
sudo ./ap-tools install rke2
```

## Open Source references
- Rancher RKE2 - https://docs.rke2.io/
- Kubernetes DNS Utility - https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- MetalLB - https://metallb.io/
- Longhorn - https://longhorn.io/
- HAProxy Tech kubernetes-ingress - https://www.haproxy.com/documentation/kubernetes-ingress/
- Harbor - https://goharbor.io/
- NGINX - https://nginx.org/  

## Dell Technologies references
- Dell Automation Platform - https://www.dell.com/en-us/lp/dt/automation-platform  

## Author notes
Thanks to all the nerds out there who think infrastructure automation is fun and motivated me to make this tool!  