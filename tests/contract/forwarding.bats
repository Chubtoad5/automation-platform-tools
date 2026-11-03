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
  sent 'PROJECTS=a'
  sent 'HARBOR_VERSION=2.15.0'
  sent 'HARBOR_PORT=8443'
  sent 'HARBOR_USERNAME=ops'
  sent 'HARBOR_PASSWORD=Secret1pass'
  sent 'REGISTRY_COMMON_NAME=reg.example'
  sent 'DURATION_DAYS=30'
}
@test "ap-tools turns off RKE2's built-in ingress, because it installs its own" {
  [ "$INSTALL_INGRESS" = "false" ]
  grep -q 'INSTALL_INGRESS=$INSTALL_INGRESS' "$BATS_TEST_DIRNAME/../../ap-tools"
}
@test "the bundle's name and sentinel stay the same" {
  grep -q 'ap-offline.tar.gz' "$BATS_TEST_DIRNAME/../../ap-tools"
}
@test "the sub-tool branch overrides still exist" {
  for v in swfs_feature_branch rke2_feature_branch harbor_feature_branch dns_feature_branch; do
    grep -q "^$v=" "$BATS_TEST_DIRNAME/../../ap-tools"
  done
}
