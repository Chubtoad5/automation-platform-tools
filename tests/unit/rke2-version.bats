#!/usr/bin/env bats
# D3 (spec 30): which RKE2_VERSION install and join pass to rke2_installer.sh, set or unset, fresh, re-run and join.
load ../helpers
setup() {
  setup_stubs
  load_script ap-tools
  AIR_GAPPED_MODE=0; INSTALL_MODE=1; JOIN_MODE=0
  user_set_rke2_version=""
  RKE2_VERSION=v1.36.6+rke2r1
  running_rke2_version() { :; }   # a fresh host: no rke2 service
}
running() { eval "running_rke2_version() { echo '$1'; }"; }

@test "the default is v1.36.6, and the pin is rke2-installer v2.0.0" {
  run env -u RKE2_VERSION -u RKE2_INSTALLER_REF -u rke2_feature_branch bash -c 'source "$1" >/dev/null 2>&1; echo "$RKE2_VERSION $RKE2_INSTALLER_REF"' _ "$BATS_TEST_DIRNAME/../../ap-tools"
  [ "$output" = "v1.36.6+rke2r1 v2.0.0" ]
}
@test "RKE2_VERSION from the environment or inputs.env counts as set; empty or absent doesn't" {
  run env RKE2_VERSION=v1.35.10+rke2r1 bash -c 'source "$1" >/dev/null 2>&1; echo "[$user_set_rke2_version]"' _ "$BATS_TEST_DIRNAME/../../ap-tools"
  [ "$output" = "[x]" ]
  run env RKE2_VERSION= bash -c 'source "$1" >/dev/null 2>&1; echo "[$user_set_rke2_version] $RKE2_VERSION"' _ "$BATS_TEST_DIRNAME/../../ap-tools"
  [ "$output" = "[] v1.36.6+rke2r1" ]
  run env -u RKE2_VERSION bash -c 'source "$1" >/dev/null 2>&1; echo "[$user_set_rke2_version]"' _ "$BATS_TEST_DIRNAME/../../ap-tools"
  [ "$output" = "[]" ]
  dir=$(mktemp -d); printf 'RKE2_VERSION="${RKE2_VERSION:-v1.35.10+rke2r1}"\n' > "$dir/inputs.env"
  run env -u RKE2_VERSION AP_TOOLS_ENV_FILE="$dir/inputs.env" bash -c 'source "$1" >/dev/null 2>&1; echo "[$user_set_rke2_version] $RKE2_VERSION"' _ "$BATS_TEST_DIRNAME/../../ap-tools"
  [ "$output" = "[x] v1.35.10+rke2r1" ]
}
@test "unset, fresh online install: ap-tools' default" {
  resolve_rke2_version_arg
  [ "$RKE2_VERSION_ARG" = v1.36.6+rke2r1 ]
}
@test "unset, re-run of install on a node running 1.34.5: the running version, with a note on how to upgrade" {
  running v1.34.5+rke2r1
  run resolve_rke2_version_arg
  [[ "$output" == *"keeping the running v1.34.5+rke2r1"* ]]
  [[ "$output" == *"upgrade rke2"* ]]
  resolve_rke2_version_arg >/dev/null
  [ "$RKE2_VERSION_ARG" = v1.34.5+rke2r1 ]
}
@test "unset, re-run of install on a node already on the default: the same version, quietly" {
  running v1.36.6+rke2r1
  run resolve_rke2_version_arg
  [ -z "$output" ]
}
@test "unset, join: none, so rke2 takes the cluster's version" {
  JOIN_MODE=1; INSTALL_MODE=0
  running v1.34.5+rke2r1
  resolve_rke2_version_arg >/dev/null
  [ -z "$RKE2_VERSION_ARG" ]
}
@test "unset, air-gapped install: none, so rke2 takes the bundle's version" {
  AIR_GAPPED_MODE=1
  resolve_rke2_version_arg >/dev/null
  [ -z "$RKE2_VERSION_ARG" ]
}
@test "unset, online push-only: ap-tools' default, even with RKE2 running" {
  INSTALL_MODE=0
  running v1.34.5+rke2r1
  resolve_rke2_version_arg
  [ "$RKE2_VERSION_ARG" = v1.36.6+rke2r1 ]
}
@test "set: always passed, for a fresh install, a re-run, a join and air-gapped" {
  user_set_rke2_version=x; RKE2_VERSION=v1.35.10+rke2r1
  resolve_rke2_version_arg; [ "$RKE2_VERSION_ARG" = v1.35.10+rke2r1 ]
  running v1.34.5+rke2r1
  resolve_rke2_version_arg; [ "$RKE2_VERSION_ARG" = v1.35.10+rke2r1 ]
  JOIN_MODE=1; INSTALL_MODE=0
  resolve_rke2_version_arg; [ "$RKE2_VERSION_ARG" = v1.35.10+rke2r1 ]
  AIR_GAPPED_MODE=1
  resolve_rke2_version_arg; [ "$RKE2_VERSION_ARG" = v1.35.10+rke2r1 ]
}
@test "end to end: an unset join reaches rke2_installer.sh as an empty RKE2_VERSION" {
  base_dir=$STUB_DIR; WORKING_DIR="$STUB_DIR/work"
  fake() { mkdir -p "$(dirname "$1")"; printf '#!/bin/bash\n{ echo "ARGS $*"; env; } >> "$STUB_LOG"\n' > "$1"; chmod +x "$1"; }
  INSTALL_MODE=0; JOIN_MODE=1; PUSH_MODE=0; REGISTRY_MODE=0; INSTALL_TYPE=push-only
  RKE2_CMD_ARGS=(join agent server.example token)
  run_debug() { :; }
  check_rke2_service_running() { :; }
  set_longhorn_packages() { longhorn_packages=""; }
  install_packages_check() { fake "$WORKING_DIR/ap-utilities/packages/install_packages.sh"; }
  rke2_installer_check() { fake "$WORKING_DIR/rke2/rke2_installer.sh"; }
  enable_iscsid() { :; }
  run_install_join_push
  grep -qxF 'ARGS join agent server.example token' "$STUB_LOG"
  grep -qxF 'RKE2_VERSION=' "$STUB_LOG"
}
@test "the running version is read from rke2's own binary under RKE2_DATA" {
  unset -f running_rke2_version
  load_script ap-tools
  RKE2_DATA=$STUB_DIR/data
  mkdir -p "$RKE2_DATA/bin"
  printf '#!/bin/bash\necho "rke2 version v1.34.5+rke2r1 (abc)"\necho "go version go1.24"\n' > "$RKE2_DATA/bin/rke2"
  chmod +x "$RKE2_DATA/bin/rke2"
  stub systemctl 'exit 0'
  [ "$(running_rke2_version)" = v1.34.5+rke2r1 ]
  stub systemctl 'exit 3'
  [ -z "$(running_rke2_version)" ]
}
