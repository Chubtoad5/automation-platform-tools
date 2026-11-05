# Test helpers. Run with: bats tests/unit tests/contract
# Stubs go early on PATH, and each one logs its arguments to $STUB_LOG.
setup_stubs() {
  STUB_DIR=$(mktemp -d)
  export STUB_LOG="$STUB_DIR/calls.log"
  : > "$STUB_LOG"
  PATH="$STUB_DIR:$PATH"
}
stub() { # stub <name> [script body]
  local name=$1 body=${2:-exit 0}
  cat > "$STUB_DIR/$name" <<STUB
#!/bin/bash
echo "$name \$*" >> "\$STUB_LOG"
$body
STUB
  chmod +x "$STUB_DIR/$name"
}
called() { grep -qF -- "$1" "$STUB_LOG"; }
# Source a script for its functions. Its strict mode and any EXIT trap would otherwise take over the test shell.
load_script() {
  local bats_traps
  bats_traps=$(trap -p EXIT ERR)
  # shellcheck disable=SC1090
  source "$BATS_TEST_DIRNAME/../../$1"
  trap - EXIT ERR
  eval "$bats_traps"
  # Bats fails a test through errexit, so that stays on. The script's other strict settings don't belong here.
  set -e
  set +u
  set +o pipefail
}
