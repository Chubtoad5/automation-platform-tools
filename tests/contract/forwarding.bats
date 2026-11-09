#!/usr/bin/env bats
# What this tool sends to its sub-installers. Each one is replaced by a stub that records its arguments and environment.
load ../helpers
setup() {
  load_script ap-tools
  setup_stubs
  base_dir=$STUB_DIR
  WORKING_DIR="$STUB_DIR/work"
  AIR_GAPPED_MODE=0
  # Sub-installers are fetched from GitHub in real runs
  fetch_subtool() { :; }
  fake() { # fake <path> : a sub-installer that records what it was given
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<'F'
#!/bin/bash
{ echo "ARGS $*"; env; } >> "$STUB_LOG"
F
    chmod +x "$1"
  }
}
sent() { grep -qxF -- "$1" "$STUB_LOG"; }
@test "install harbor forwards its settings" {
  fake "$WORKING_DIR/ap-utilities/harbor/install_harbor.sh"
  PROJECTS="a b"; HARBOR_VERSION=2.15.0; HARBOR_PORT=8443; SWFS_HARBOR_USER=ops; SWFS_HARBOR_PASS=Secret1pass
  COUNTRY=US; STATE=MA; LOCATION=B; ORGANIZATION=O; DURATION_DAYS=30; HARBOR_COMMON_NAME=reg.example
  run_install_harbor
  sent 'ARGS install-harbor'
  sent 'PROJECTS=a b'
  sent 'HARBOR_VERSION=2.15.0'
  sent 'HARBOR_PORT=8443'
  sent 'HARBOR_USERNAME=ops'
  sent 'HARBOR_PASSWORD=Secret1pass'
  sent 'REGISTRY_COMMON_NAME=reg.example'
  sent 'DURATION_DAYS=30'
}
install_rke2_with_stubs() {
  INSTALL_MODE=1; JOIN_MODE=0; PUSH_MODE=0; REGISTRY_MODE=0; INSTALL_TYPE=push-only
  RKE2_CMD_ARGS="install"
  run_debug() { :; }
  check_rke2_service_running() { :; }
  set_longhorn_packages() { longhorn_packages=""; }
  install_packages_check() { fake "$WORKING_DIR/ap-utilities/packages/install_packages.sh"; }
  rke2_installer_check() { fake "$WORKING_DIR/rke2/rke2_installer.sh"; }
  run_install_join_push
}
@test "install rke2 sends INSTALL_INGRESS=false, because ap-tools installs its own ingress" {
  install_rke2_with_stubs
  sent 'ARGS install'
  sent 'INSTALL_INGRESS=false'
}
@test "install rke2 forwards its other settings" {
  RKE2_VERSION=v1.0.0+rke2r1; CNI_TYPE=calico; NTP_SERVERS=ntp.example; MAX_PODS=250; MGMT_IP=10.0.0.5
  install_rke2_with_stubs
  sent 'RKE2_VERSION=v1.0.0+rke2r1'
  sent 'CNI_TYPE=calico'
  sent 'NTP_SERVERS=ntp.example'
  sent 'MAX_PODS=250'
  sent 'MGMT_IP=10.0.0.5'
}
@test "the bundle's name and sentinel stay the same" {
  grep -q 'ap-offline.tar.gz' "$BATS_TEST_DIRNAME/../../ap-tools"
}
@test "the sub-tool branch overrides still exist, and still choose what's fetched" {
  # Spec 13 moved them into the pins (RKE2_INSTALLER_REF=${...:-${rke2_feature_branch:-v1.3.0}}), so test what they do
  for pair in swfs_feature_branch:SWFS_INSTALLER_REF rke2_feature_branch:RKE2_INSTALLER_REF \
              harbor_feature_branch:HARBOR_INSTALLER_REF dns_feature_branch:DNS_INSTALLER_REF; do
    v=${pair%%:*} r=${pair##*:}
    run env -u "$r" "$v=test-branch" bash -c 'source "$1" >/dev/null 2>&1; echo "${!2}"' _ "$BATS_TEST_DIRNAME/../../ap-tools" "$r"
    [ "$output" = test-branch ] || { echo "$v didn't reach $r: $output"; false; }
  done
}
@test "spec 13: the helper pins reach the installers, so one set covers the chain" {
  fake "$WORKING_DIR/ap-utilities/harbor/install_harbor.sh"
  run_install_harbor
  sent 'INSTALL_PACKAGES_REF=v1.1.2'
  sent 'IMAGE_PULL_PUSH_REF=v1.1.1'
}
@test "spec 13: every default sub-tool pin is a release tag" {
  pins=$(grep -E '^(RKE2|HARBOR|SWFS|DNS)_INSTALLER_REF=|^(IMAGE_PULL_PUSH|INSTALL_PACKAGES)_REF=' "$BATS_TEST_DIRNAME/../../ap-tools")
  [ "$(wc -l <<< "$pins")" -eq 6 ]
  while read -r line; do
    [[ "$line" =~ :-v[0-9]+\.[0-9]+\.[0-9]+\}+\"$ ]] || { echo "not a release tag: $line"; false; }
  done <<< "$pins"
}
@test "spec 16: offline-prep's rke2, SeaweedFS and images-pull-push saves name the same offer contact" {
  LICENSE_OFFER_CONTACT="Ops <ops@example.invalid>"
  rke2_installer_check() { :; }
  image_pull_push_check() { :; }
  fake "$WORKING_DIR/rke2/rke2_installer.sh"
  fake "$WORKING_DIR/ap-utilities/swfs/install-seaweedfs"
  fake "$WORKING_DIR/ap-utilities/images/image_pull_push.sh"
  download_rke2
  download_swfs
  save_addon_images
  [ "$(grep -c '^LICENSE_OFFER_CONTACT=Ops <ops@example.invalid>$' "$STUB_LOG")" -eq 3 ]
  sent 'ARGS save'
  sent 'ARGS -f ap-addon-images.txt save'
}
