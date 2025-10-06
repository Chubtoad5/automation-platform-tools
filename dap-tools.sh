#!/bin/bash

# --- Script Configuration - DO NOT EDIT --- #
set -o errexit
set -o nounset
set -o pipefail

# --- USER DEFINED VARIABLES ---#
RKE2_VERSION=v1.32.5+rke2r1
CNI_TYPE=calico
CLUSTER_CIDR="10.42.0.0/16"
SERVICE_CIDR="10.43.0.0/16"
MAX_PODS=180
INSTALL_LOCAL_PATH_PROVISIONER=false
LOCAL_PATH_PROVISIONER_VERSION=v0.0.32
INSTALL_DNS_UTILITY=true
DEBUG=1
HELM_VERSION=3.12.0
LONGHORN_VERSION=1.9.2
METALLB_VERSION=0.15.2
KUBERNETES_INGRESS_VERSION=1.45.0
HAPROXY_APP_VERSION=3.1.7

# --- INTERNAL VARIABLES - DO NOT EDIT --- #
ENABLE_CIS=false
INSTALL_INGRESS=false
INSTALL_SERVICELB=false
user_name=$SUDO_USER
SCRIPT_NAME=$(basename "$0")
AIR_GAPPED_MODE=0
OFFLINE_PREP_MODE=0
PUSH_MODE=0
INSTALL_MODE=0
INSTALL_TYPE=""
TLS_SAN_MODE=0
TLS_SAN=""
JOIN_MODE=0
JOIN_TYPE="server"
JOIN_TOKEN=""
JOIN_SERVER_FQDN=""
base_dir=$(pwd)
WORKING_DIR="$base_dir/dap-install"
REGISTRY_MODE=0
REGISTRY_INFO=""
REG_USER=""
REG_PASS=""
fqdn_pattern='^([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}$'
ipv4_pattern='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'

# --- USAGE FUNCTION --- #

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [install rke2] [offline-prep] [push] [join server|agent [server-fqdn] [join-token-string]] [-tls-san [server-fqdn-ip]] [-registry [registry:port username password]]

Commands:
  install      : Installs specified component and any dependencies. If a dap-offline.tar.gz file is in the directory, component will be installed in air-gapped mode.
  offline-prep : Creates an offline tar package which contains all dependencies for an air-gapped installation, cannot be used with [install] [push] [join].
  push         : Pushes container images images to the specified registry. [-registry] must be specified.
  join         : Joins the host to an existing cluster as a [server] or [agent]. [join-token-string] must be specified.
  -tls-san     : Adds specified FQDN to rke2 tls-san configuration for multi-node setup.
  -registry    : When used with [install rke2], configures a private registry for the cluster. When used with [push], pushes container images to the registry.

EOF
    exit 1
}

# --- Start Argument parsing and validation --- #

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run with root privileges."
   echo "Type './$SCRIPT_NAME -h' for help."
   exit 1
fi

# Check for no arguments, and show usage if none are provided
if [[ "$#" -eq 0 ]]; then
    echo "Error: No arguments provided."
    usage
fi

# Check for the correct argument syntax
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        install)
            INSTALL_MODE=1
            INSTALL_TYPE="${2:-}"
            # if [[ -z "$INSTALL_TYPE" || "$INSTALL_TYPE" != "rke2" && "$INSTALL_TYPE" != "harbor" && "$INSTALL_TYPE" != "nginx" ]]; then
            if [[ -z "$INSTALL_TYPE" || "$INSTALL_TYPE" != "rke2" ]]; then
                # echo "Error: 'install' command requires an install type. Format: install [rke2|harbor|nginx]"
                echo "Error: 'install' command requires an install type. Format: install [rke2]"
                echo "Type './$SCRIPT_NAME -h' for help."
                exit 1
            fi
            shift
            shift
            ;;
        offline-prep)
            OFFLINE_PREP_MODE=1
            shift
            ;;
        push)
            PUSH_MODE=1
            shift
            ;;
        join)
            JOIN_MODE=1
            JOIN_TYPE="${2:-}"
            JOIN_SERVER_FQDN="${3:-}"
            JOIN_TOKEN="${4:-}"
            if [[ -z "$JOIN_TYPE" || "$JOIN_TYPE" != "agent" && "$JOIN_TYPE" != "server" ]]; then
                echo "Error: 'join' command requires a join type. Format: join [server|agent] [join-token-string]"
                echo "Type './$SCRIPT_NAME -h' for help."
                exit 1
            fi
            if [[ -z "$JOIN_SERVER_FQDN" ]]; then
                echo "Error: 'join' command requires a server fqdn/ip. Format: join [server|agent] [join-token-string]"
                echo "Type './$SCRIPT_NAME -h' for help."
                exit 1
            fi
            if [[ -z "$JOIN_TOKEN" ]]; then
                echo "Error: 'join' command requires a join token. Format: join [server|agent] [join-token-string]"
                echo "Type './$SCRIPT_NAME -h' for help."
                exit 1
            fi
            shift
            shift
            shift
            shift
            ;;
        -tls-san)
            TLS_SAN_MODE=1
            TLS_SAN="${2:-}"
            if [[ -z "$TLS_SAN" ]]; then
                echo "Error: 'tls-san' command requires a server fqdn/ip. Format: tls-san [server-fqdn-ip]"
                echo "Type './$SCRIPT_NAME -h' for help."
                exit 1
            fi
            shift
            shift
            ;;
        -registry)
            REGISTRY_MODE=1
            REGISTRY_INFO="$2"
            REG_USER="${3:-}"
            REG_PASS="${4:-}"
            if [[ -z "$REG_USER" || -z "$REG_PASS" ]]; then
                echo "Error: Registry info requires a username and password. Format: registry [registry:port username password]"
                echo "Type './$SCRIPT_NAME -h' for help."
                exit 1
            fi
            shift
            shift
            shift
            shift
            ;;
        *)
            echo "Error: Invalid argument '$1'."
            usage
            ;;
    esac
done

# Run validation to ensure the correct arguments and modes have been passed.

# Verify AIR_GAPPED_MODE based on dap-offline.tar.gz file presence
[[ ! -f $base_dir/dap-offline.tar.gz ]] || AIR_GAPPED_MODE=1

# Verify OFFLINE_PREP_MODE is not used with other commands or flags
if [[ "$OFFLINE_PREP_MODE" == "1" ]]; then
    if [[ $JOIN_MODE == "1" || $INSTALL_MODE == "1" || $PUSH_MODE == "1" ]]; then
        echo "Error: 'offline-prep' command cannot be used with 'join, install, or push'."
        echo "Type './$SCRIPT_NAME -h' for help."
        exit 1
    fi
    if [[ $TLS_SAN_MODE == "1" || $REGISTRY_MODE == "1" ]]; then
        echo "Error: 'offline-prep' command cannot be used with '-tls-san or -registry'."
        echo "Type './$SCRIPT_NAME -h' for help."
        exit 1
    fi
    if [[ $AIR_GAPPED_MODE == "1" ]]; then
        echo "Error: Air-gapped mode detected,'offline-prep' requires an internet connection."
        echo "Type './$SCRIPT_NAME -h' for help."
        exit 1
    fi
fi


# Displays the parsed and validated arguments
display_args() {
    echo "---"
    echo "Arguments parsed successfully, script will run with:"
    echo "AIR_GAPPED_MODE: $AIR_GAPPED_MODE"
    echo "INSTALL_MODE: $INSTALL_MODE"
    echo "INSTALL_TYPE: $INSTALL_TYPE"
    echo "TLS_SAN_MODE: $TLS_SAN_MODE"
    echo "TLS_SAN: $TLS_SAN"
    echo "OFFLINE_PREP_MODE: $OFFLINE_PREP_MODE"
    echo "JOIN_MODE: $JOIN_MODE"
    echo "JOIN_TYPE: $JOIN_TYPE"
    echo "JOIN_SERVER_FQDN: $JOIN_SERVER_FQDN"
    echo "JOIN_TOKEN: $JOIN_TOKEN"
    echo "PUSH_MODE: $PUSH_MODE"
    echo "REGISTRY_MODE: $REGISTRY_MODE"
    echo "REGISTRY_INFO: $REGISTRY_INFO"
    echo "REG_USER: $REG_USER"
    echo "REG_PASS: $REG_PASS"
    echo "---"
}
# --- End of Argument Parsing --- #

# -- Install & Join Definitions -- #

rke2_install () {
  echo "Installing rke2..."
}

helm_install () {
  echo "Installing helm..."
}

helm_install_haproxy () {
  echo "Installing helm chart..."
}

helm_install_longhorn () {
  echo "Installing helm chart..."
}

helm_install_metallb () {
  echo "Installing helm chart..."
}

dap_host_config () {
  echo "Configuring host settings for DAP..."
  echo -e "fs.inotify.max_user_watches = 1048576\nfs.inotify.max_user_instances = 1024" | tee /etc/sysctl.d/10-dap-orchestrator.conf
  systemctl restart systemd-sysctl
  if [ $? -ne 0 ]; then
    echo "Error: systemd-sysctl.service failed to restart."
    exit 1 
  else
    echo "systemd-sysctl.service restarted successfully."
  fi
}

# -- Offline Prep Definitions -- #

run_offline_prep () {
  if [[ $OFFLINE_PREP_MODE == "1" ]]; then
      echo "--- Running offline prep workflow ---"
      download_packages
      download_rke2
      download_helm_binaries
      download_helm_images
      create_offline_prep_archive
      echo "--- Offline prep workflow complete ---"
      echo "Copy the archive to an air-gapped host running the same version of $os_id"
  fi
}

download_packages () {
  install_packages_check
  cd $WORKING_DIR/dap-utilities/packages
  ./install_packages.sh save jq zip unzip
  cd $base_dir
}

download_rke2 () {
  rke2_installer_check
  cd $WORKING_DIR/rke2
  ./rke2_installer.sh save
  cd $base_dir
}

download_helm_binaries () {
  echo "Downloading helm binary..."
  curl -fsSLo $WORKING_DIR/dap-utilities/helm/helm-v$HELM_VERSION-linux-amd64.tar.gz https://get.helm.sh/helm-v$HELM_VERSION-linux-amd64.tar.gz
  echo "Installing helm binary..."
  tar -xvf $WORKING_DIR/dap-utilities/helm/helm-v$HELM_VERSION-linux-amd64.tar.gz
  mv linux-amd64/helm /usr/local/bin/helm
  rm -rf linux-amd64
  echo "Adding helm charts..."
  helm repo add metallb https://metallb.github.io/metallb
  helm repo add haproxytech https://haproxytech.github.io/helm-charts
  helm repo add longhorn https://charts.longhorn.io
  helm repo update
  echo "Pulling helm charts..."

  # HAPROXY
  mkdir -p $WORKING_DIR/dap-utilities/helm/haproxy
  cd $WORKING_DIR/dap-utilities/helm/haproxy
  helm pull haproxytech/kubernetes-ingress --version $KUBERNETES_INGRESS_VERSION
  echo "haproxytech/kubernetes-ingress:$HAPROXY_APP_VERSION" > haproxy-images.txt

  # LONGHORN
  mkdir -p $WORKING_DIR/dap-utilities/helm/longhorn
  cd $WORKING_DIR/dap-utilities/helm/longhorn
  helm pull longhorn/longhorn --version $LONGHORN_VERSION
  # curl -OL https://github.com/longhorn/longhorn/raw/refs/heads/v1.9.x/chart/values.yaml
  curl -OL https://github.com/longhorn/longhorn/releases/download/v$LONGHORN_VERSION/longhorn-images.txt

  # METALLB
  mkdir -p $WORKING_DIR/dap-utilities/helm/metallb
  cd $WORKING_DIR/dap-utilities/helm/metallb
  helm pull metallb/metallb --version $METALLB_VERSION
  cat > metallb-images.txt <<EOF
quay.io/metallb/controller:v$METALLB_VERSION
quay.io/metallb/speaker:v$METALLB_VERSION
EOF

  cd $base_dir
}

download_helm_images () {
  cat $WORKING_DIR/dap-utilities/helm/longhorn/longhorn-images.txt > $WORKING_DIR/dap-utilities/images/helm-images.txt
  cat $WORKING_DIR/dap-utilities/helm/haproxy/haproxy-images.txt >> $WORKING_DIR/dap-utilities/images/helm-images.txt
  cat $WORKING_DIR/dap-utilities/helm/metallb/metallb-images.txt >> $WORKING_DIR/dap-utilities/images/helm-images.txt
  image_pull_push_check
  cd $WORKING_DIR/dap-utilities/images
  ./image_pull_push.sh -f ./helm-images.txt save
  cd $base_dir

}

create_offline_prep_archive () {
    # saves downloaded files into dap-offline.tar.gz
    echo "Creating final archive..."
    tar -czf dap-offline.tar.gz dap-install dap-tools.sh
    echo "Air-gapped archive 'dap-offline.tar.gz' created."
}

# -- Push Definitions -- #

# --- Helper Functions --- #

create_working_dir () {
    # check for rke2-install directory and supporting directories, then create them
    [ -d "$WORKING_DIR" ] || mkdir -p "$WORKING_DIR"
    [ -d "$WORKING_DIR/dap-utilities/packages" ] || mkdir -p "$WORKING_DIR/dap-utilities/packages"
    [ -d "$WORKING_DIR/dap-utilities/images" ] || mkdir -p "$WORKING_DIR/dap-utilities/images"
    [ -d "$WORKING_DIR/dap-utilities/helm" ] || mkdir -p "$WORKING_DIR/dap-utilities/helm"
    [ -d "$WORKING_DIR/rke2" ] || mkdir -p "$WORKING_DIR/rke2"
}


os_check () {
    # Get OS information from /etc/os-release
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        echo "OS type is: $ID"
        os_id="$ID"
    else
        echo "Unknown or unsupported OS $os_id."
        exit 1
    fi
    if [[ ! "$os_id" =~ ^(ubuntu|debian|rhel|centos|rocky|almalinux|fedora|sles|opensuse-leap)$ ]]; then
        echo "Unknown or unsupported OS $os_id."
        exit 1
    fi
}

install_packages_check () {
    if [[ ! -f $WORKING_DIR/dap-utilities/packages/install_packages.sh ]]; then
        echo "Downloading install_packages.sh..."
        curl -sfL https://github.com/Chubtoad5/install-packages/raw/refs/heads/main/install_packages.sh  -o $WORKING_DIR/dap-utilities/packages/install_packages.sh
        chmod +x $WORKING_DIR/dap-utilities/packages/install_packages.sh
    fi
}

image_pull_push_check () {
    if [[ ! -f $WORKING_DIR/dap-utilities/images/image_pull_push.sh ]]; then
        echo "Downloading image_pull_push.sh..."
        curl -sfL https://github.com/Chubtoad5/images-pull-push/raw/refs/heads/main/image_pull_push.sh  -o $WORKING_DIR/dap-utilities/images/image_pull_push.sh
        chmod +x $WORKING_DIR/dap-utilities/images/image_pull_push.sh
    fi
}

rke2_installer_check () {
    if [[ ! -f $WORKING_DIR/rke2/rke2_installer.sh ]]; then
        echo "Downloading rke2_installer.sh..."
        curl -sfL https://github.com/Chubtoad5/rke2-installer/raw/refs/heads/main/rke2_installer.sh  -o $WORKING_DIR/rke2/rke2_installer.sh
        chmod +x $WORKING_DIR/rke2/rke2_installer.sh
    fi
}

check_namespace_pods_ready() {
  # Run this function as 'check_namespace_pods_ready $namespace', no argument will default to kube-system
  local timeout_seconds=120
  local start_time=$(date +%s)
  local ns=${1:-"kube-system"}
  while true; do
    local completed_pods=$(kubectl get pods -n $ns --field-selector status.phase=Succeeded -o name)
    echo "Checking pod status and removing Completed pods in $ns namespace..."
    for pod_name in $completed_pods; do
      kubectl delete -n $ns "$pod_name" --ignore-not-found
    done
    local current_pods_not_ready=$(kubectl get pods -n $ns --no-headers | awk '{print $2}' | awk -F'/' '{if ($1 != $2) print $0}' | wc -l)
    local elapsed_time=$(($(date +%s) - start_time))
    if [ "$elapsed_time" -ge "$timeout_seconds" ]; then
      echo "Error: Timeout reached after $timeout_seconds seconds. Not all pods are ready." >&2
      kubectl get pods -A
      return 1
    fi
    if [ "$current_pods_not_ready" -eq 0 ]; then
      break
    fi
    echo "Wating on $current_pods_not_ready pods..."
    echo "Elapsed: ${elapsed_time}s/${timeout_seconds}s"
    sleep 10
  done
  echo "All pods are ready in $ns namespace!"
  return 0
}

run_debug() {
  # Use this to hide the output of functions or helper scripts when they are not needed.
  if [ "$DEBUG" = "1" ]; then
    local GREEN=$(tput setaf 2)
    local RED=$(tput setaf 1)
    local NC=$(tput sgr0)
    local CHECKMARK='\u2714'
    local CROSSMARK='\u2717'
    local SUCCESS_MSG=${2:-"Success"}
    local ERROR_MSG=${3:-"Error"}
    echo "--- Running '$*' with DEBUG enabled---"
    "$@"
    local status=$?
    if [ "$status" -eq 0 ]; then
        echo -e "--- DEBUG: Finished '$*' ${GREEN}${CHECKMARK} ${SUCCESS_MSG}${NC} ---"
    else
        echo -e "--- DEBUG: Finished '$*' ${RED}${CROSSMARK} ${ERROR_MSG}${NC} ---" >&2
    fi
    return $status
  else
    echo "Running '$*'..."
    "$@" > /dev/null 2>&1
    return $?
  fi
}

cleanup () {
    if [[ $INSTALL_MODE -eq 1 || $JOIN_MODE -eq 1 ]]; then
        echo "Installation detected, no cleanup required..."
    else
        echo "Cleaning up..."
        rm -rf "$WORKING_DIR"
    fi
}

# --- Main Script Execution --- #