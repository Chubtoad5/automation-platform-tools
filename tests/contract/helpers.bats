#!/usr/bin/env bats
# Nightly drift run: what this repo needs from the helpers, checked against their main.
@test "install_packages.sh still takes its modes" {
  [ -n "${HELPER_DIR:-}" ] || skip "only in the nightly drift run"
  [ -f "$HELPER_DIR/install-packages/install_packages.sh" ] || skip "this repo is the helper"
  for mode in online offline save; do grep -q "$mode)" "$HELPER_DIR/install-packages/install_packages.sh"; done
  grep -q 'offline-packages.tar.gz' "$HELPER_DIR/install-packages/install_packages.sh"
}
@test "image_pull_push.sh still takes its commands, and keeps its archive layout" {
  [ -n "${HELPER_DIR:-}" ] || skip "only in the nightly drift run"
  [ -f "$HELPER_DIR/images-pull-push/image_pull_push.sh" ] || skip "this repo is the helper"
  for c in keep save push docker reg-cert; do grep -q "$c)" "$HELPER_DIR/images-pull-push/image_pull_push.sh"; done
  grep -q "images.tar.gz" "$HELPER_DIR/images-pull-push/image_pull_push.sh"
  grep -q 'container_images_' "$HELPER_DIR/images-pull-push/image_pull_push.sh"
}
