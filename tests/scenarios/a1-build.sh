#!/bin/bash
# A1, on the host that builds the bundle: ap-tools offline-prep (no Dell bundles, as by default), hand the archive on.
set -uo pipefail
REPO=$PWD
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
W=$(mktemp -d -p /var/tmp); cd "$W" || exit 1
cp "$REPO/ap-tools" .; chmod +x ap-tools
if DEBUG=0 ./ap-tools offline-prep > "$W/o" 2>&1 && [ -s ap-offline.tar.gz ]; then
  ok "offline-prep builds ap-offline.tar.gz ($(du -h ap-offline.tar.gz | cut -f1))"
  cp ap-offline.tar.gz "$CI_HANDOFF/" && ok "hand the bundle on" || bad "hand the bundle on"
  [ -s ap-install/subtool-pins.txt ] && ok "the bundle records its sub-tools' pins" || bad "no ap-install/subtool-pins.txt"
else
  bad "offline-prep"; tail -10 "$W/o" | cut -c1-170
fi
echo "=== exit $fail"; exit $fail
