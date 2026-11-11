#!/usr/bin/env bats
# Spec 13: ap-tools fetches each sub-tool from the release it pins, not main. A tag or commit is cached, a branch is
# fetched again online, and an air-gapped run uses the bundled copy and never fetches.
load ../helpers

PINS=(RKE2_INSTALLER_REF HARBOR_INSTALLER_REF SWFS_INSTALLER_REF DNS_INSTALLER_REF IMAGE_PULL_PUSH_REF INSTALL_PACKAGES_REF)

setup() {
  unset "${PINS[@]}" rke2_feature_branch harbor_feature_branch swfs_feature_branch dns_feature_branch
  load_script ap-tools
  setup_stubs
  base_dir=$BATS_TEST_TMPDIR
  WORKING_DIR=$BATS_TEST_TMPDIR/ap-install
  AIR_GAPPED_MODE=0
  mkdir -p "$WORKING_DIR/rke2"
  DEST=$WORKING_DIR/rke2/rke2_installer.sh
  REC=$WORKING_DIR/rke2/.rke2_installer.sh.branch
  # A curl that writes a small script to its -o path
  stub curl 'out=""; prev=""; for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
printf "#!/bin/bash\necho fetched\n" > "$out"'
}
fetch_rke2() { fetch_subtool "$DEST" "$(subtool_url rke2-installer "$RKE2_INSTALLER_REF" rke2_installer.sh)" "$RKE2_INSTALLER_REF"; }

@test "each sub-tool is pinned to its release" {
  [ "$RKE2_INSTALLER_REF" = v1.3.1 ]
  [ "$HARBOR_INSTALLER_REF" = v1.3.0 ]
  [ "$SWFS_INSTALLER_REF" = v1.3.0 ]
  [ "$DNS_INSTALLER_REF" = v1.3.0 ]
  [ "$IMAGE_PULL_PUSH_REF" = v1.1.2 ]
  [ "$INSTALL_PACKAGES_REF" = v1.1.3 ]
}
@test "a *_feature_branch still wins over the pin, and an explicit *_REF wins over both" {
  unset "${PINS[@]}"
  export rke2_feature_branch=my-branch swfs_feature_branch=x HARBOR_INSTALLER_REF=v9.9.9 harbor_feature_branch=y
  load_script ap-tools
  [ "$RKE2_INSTALLER_REF" = my-branch ]
  [ "$SWFS_INSTALLER_REF" = x ]
  [ "$HARBOR_INSTALLER_REF" = v9.9.9 ]
  [ "$DNS_INSTALLER_REF" = v1.3.0 ]
}
@test "the two helper pins reach every installer ap-tools runs" {
  run bash -c 'echo "$IMAGE_PULL_PUSH_REF $INSTALL_PACKAGES_REF"'
  [ "$output" = "v1.1.2 v1.1.3" ]
}
@test "the fetch URL takes a branch, a tag or a commit" {
  [ "$(subtool_url rke2-installer v1.3.0 rke2_installer.sh)" = https://raw.githubusercontent.com/Chubtoad5/rke2-installer/v1.3.0/rke2_installer.sh ]
}
@test "a vX.Y.Z tag or a full commit can't change; a branch or anything else can" {
  ref_is_immutable v1.3.0
  ref_is_immutable 0123456789abcdef0123456789abcdef01234567
  for r in main feature/x v1.3 1.3.0 v1.3.0-rc1 0123abc; do ! ref_is_immutable "$r" || false; done
}
@test "a copy from the same tag is reused" {
  fetch_rke2 >/dev/null
  called "curl -fsSL https://raw.githubusercontent.com/Chubtoad5/rke2-installer/v1.3.1/rke2_installer.sh"
  [ "$(cat "$REC")" = v1.3.1 ]
  : > "$STUB_LOG"
  run fetch_rke2
  [ "$status" -eq 0 ]
  ! called curl || false
}
@test "a branch is fetched again on every online run" {
  RKE2_INSTALLER_REF=main
  fetch_rke2 >/dev/null
  : > "$STUB_LOG"
  run fetch_rke2
  [ "$status" -eq 0 ]
  [[ "$output" == *"follows branch 'main', which can move; refetching"* ]]
  called curl
}
@test "a copy from main, or with no record, is replaced by the pinned release" {
  echo old > "$DEST"
  run fetch_rke2
  [[ "$output" == *"came from 'main' but 'v1.3.1' was requested"* ]]
  grep -q fetched "$DEST"
  [ "$(cat "$REC")" = v1.3.1 ]
}
@test "air-gapped, the bundled copy is used even when its ref differs, and nothing is fetched" {
  AIR_GAPPED_MODE=1
  echo bundled > "$DEST"
  echo v1.2.0 > "$REC"
  run fetch_rke2
  [ "$status" -eq 0 ]
  [[ "$output" == *"using the bundled rke2_installer.sh (v1.2.0), not v1.3.1"* ]]
  ! called curl || false
  [ "$(cat "$DEST")" = bundled ]
}
@test "air-gapped with no bundled copy stops, and never fetches" {
  AIR_GAPPED_MODE=1
  run fetch_rke2
  [ "$status" -eq 1 ]
  [[ "$output" == *"isn't in the extracted ap-offline.tar.gz"* ]]
  ! called curl || false
}
@test "a failed download stops, and leaves no file behind" {
  stub curl 'exit 22'
  run fetch_rke2
  [ "$status" -eq 1 ]
  [ ! -e "$DEST" ]
  [ ! -e "$DEST.tmp" ]
}
@test "offline-prep records the pins in the bundle" {
  write_subtool_pins
  grep -q '^# ap-tools 1.2.0 offline-prep' "$WORKING_DIR/subtool-pins.txt"
  [ "$(grep -vc '^#' "$WORKING_DIR/subtool-pins.txt")" -eq 6 ]
  grep -qx 'rke2-installer v1.3.1' "$WORKING_DIR/subtool-pins.txt"
  grep -qx 'install-packages v1.1.3' "$WORKING_DIR/subtool-pins.txt"
}
@test "version prints ap-tools' version and the six pins" {
  run print_version
  [ "${lines[0]}" = "ap-tools 1.2.0" ]
  [[ "$output" == *"seaweedfs-installer"*"v1.3.0"* ]]
  [[ "$output" == *"technitium-dns-installer"*"v1.3.0"* ]]
  [[ "$output" != *"offline bundle"* ]]
}
@test "version also shows what an extracted bundle holds, or that an old bundle recorded nothing" {
  printf '# header\nrke2-installer v1.2.0\n' > "$WORKING_DIR/subtool-pins.txt"
  run print_version
  [[ "$output" == *"Sub-tools in the extracted offline bundle"*"rke2-installer"*"v1.2.0"* ]]
  rm "$WORKING_DIR/subtool-pins.txt"
  touch "$base_dir/ap-offline.tar.gz"
  run print_version
  [[ "$output" == *"isn't extracted yet"* ]]
}
@test "version on its own runs without root, and changes nothing" {
  cd "$BATS_TEST_TMPDIR"
  run bash "$BATS_TEST_DIRNAME/../../ap-tools" version
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ap-tools 1.2.0" ]
  [ ! -e "$BATS_TEST_TMPDIR/ap-install/rke2/rke2_installer.sh" ]
}
@test "version with another command is refused" {
  [ "$EUID" -eq 0 ] || skip "the root check comes first"
  cd "$BATS_TEST_TMPDIR"
  run bash "$BATS_TEST_DIRNAME/../../ap-tools" version install rke2
  [ "$status" -eq 1 ]
  [[ "$output" == *"'version' cannot be combined"* ]]
}
@test "version with an option is refused too" {
  [ "$EUID" -eq 0 ] || skip "the root check comes first"
  cd "$BATS_TEST_TMPDIR"
  for opt in "-tls-san a.b" "-registry r:443 u p" "--purge-cache"; do
    run bash "$BATS_TEST_DIRNAME/../../ap-tools" version $opt
    [ "$status" -eq 1 ]
    [[ "$output" == *"'version' cannot be combined"* ]]
  done
}
@test "install ap-bundle's copy of image_pull_push.sh keeps rke2's ref record in step" {
  body=$(declare -f install_reg_docker)
  [[ "$body" == *'"$IMAGE_PULL_PUSH_REF" > $WORKING_DIR/rke2/rke2-install/rke2-utilities/.image_pull_push.sh.ref'* ]]
}
@test "nothing fetches a sub-tool from a branch URL that can't take a tag" {
  ! grep -n 'raw/refs/heads' "$BATS_TEST_DIRNAME/../../ap-tools" || false
}
@test "spec 19: Harbor's server certificate defaults to 730 days" {
  unset DURATION_DAYS
  load_script ap-tools
  [ "$DURATION_DAYS" = 730 ]
}
