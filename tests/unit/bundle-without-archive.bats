#!/usr/bin/env bats
# Spec 15, F5: ap-install/ holds an extracted bundle, but ap-offline.tar.gz isn't beside ap-tools. Without the archive a
# run would go online and fail with no word why, so install, join, push and upgrade stop and say so.
load ../helpers
setup() {
  load_script ap-tools
  base_dir=$(mktemp -d) WORKING_DIR=""
  WORKING_DIR="$base_dir/ap-install"
  mkdir -p "$WORKING_DIR"
  AIR_GAPPED_MODE=0 AP_FORCE_ONLINE=false INSTALL_MODE=1 JOIN_MODE=0 PUSH_MODE=0 UPGRADE_MODE=0
}
@test "an extracted bundle with no archive: install stops, and says what to do" {
  echo "# pins" > "$WORKING_DIR/subtool-pins.txt"
  run check_extracted_bundle_without_archive
  [ "$status" -eq 1 ]
  [[ "$output" == *"holds an extracted offline bundle, but ap-offline.tar.gz isn't in $base_dir"* ]]
  [[ "$output" == *"AP_FORCE_ONLINE=true"* ]]
}
@test "join, push and upgrade stop too" {
  echo "# pins" > "$WORKING_DIR/subtool-pins.txt"
  INSTALL_MODE=0
  for m in JOIN_MODE PUSH_MODE UPGRADE_MODE; do
    JOIN_MODE=0 PUSH_MODE=0 UPGRADE_MODE=0
    printf -v "$m" 1
    run check_extracted_bundle_without_archive
    [ "$status" -eq 1 ]
  done
}
@test "with the archive there (air-gapped), or AP_FORCE_ONLINE=true, it goes on" {
  echo "# pins" > "$WORKING_DIR/subtool-pins.txt"
  AIR_GAPPED_MODE=1
  run check_extracted_bundle_without_archive
  [ "$status" -eq 0 ]
  AIR_GAPPED_MODE=0 AP_FORCE_ONLINE=TRUE
  run check_extracted_bundle_without_archive
  [ "$status" -eq 0 ]
}
@test "an online host's ap-install/ (no subtool-pins.txt) goes on" {
  mkdir -p "$WORKING_DIR/ap-utilities/packages"
  run check_extracted_bundle_without_archive
  [ "$status" -eq 0 ]
}
@test "uninstall and offline-prep aren't stopped" {
  echo "# pins" > "$WORKING_DIR/subtool-pins.txt"
  INSTALL_MODE=0
  run check_extracted_bundle_without_archive
  [ "$status" -eq 0 ]
}
@test "the check runs right after the archive test, before anything else" {
  grep -A1 'AIR_GAPPED_MODE=1$' "$BATS_TEST_DIRNAME/../../ap-tools" | grep -q '^check_extracted_bundle_without_archive$'
}
