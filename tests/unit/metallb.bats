#!/usr/bin/env bats
# Spec 19, AP2: MetalLB's webhook can refuse its config for a while after its pods are Ready, so the apply is retried.
load ../helpers

setup() {
  load_script ap-tools
  setup_stubs
  stub sleep
  CONF=$BATS_TEST_TMPDIR/metallb-config.yaml; : > "$CONF"
  N=$BATS_TEST_TMPDIR/n; echo 0 > "$N"
  METALLB_APPLY_WAIT=10
}
# kubectl fails its first $1 applies with the webhook error, then succeeds
kubectl_fails() {
  stub kubectl 'n=$(cat '"$N"'); echo $((n + 1)) > '"$N"'
if [ "$n" -lt '"$1"' ]; then echo "Error from server (InternalError): Internal error occurred: failed calling webhook" >&2; exit 1; fi
echo "ipaddresspool.metallb.io/default-ip-pool created"'
}

@test "AP2: two refusals, then the config applies" {
  kubectl_fails 2
  run apply_metallb_config "$CONF"
  [ "$status" -eq 0 ]
  [ "$(cat "$N")" = 3 ]
  [[ "$output" == *"try 1 of 12"* && "$output" == *"try 2 of 12"* ]]
  [[ "$output" == *"default-ip-pool created"* ]]
  [ "$(grep -c '^sleep 10' "$STUB_LOG")" = 2 ]
}
@test "AP2: it stops with the last error after 12 tries, without a last wait" {
  kubectl_fails 99
  run apply_metallb_config "$CONF"
  [ "$status" -eq 1 ]
  [ "$(cat "$N")" = 12 ]
  [[ "$output" == *"failed calling webhook"* && "$output" == *"refused its config 12 times"* ]]
  [ "$(grep -c '^sleep' "$STUB_LOG")" = 11 ]
}
@test "AP2: a first-time success applies once and doesn't wait" {
  kubectl_fails 0
  run apply_metallb_config "$CONF"
  [ "$status" -eq 0 ]
  [ "$(cat "$N")" = 1 ]
  ! grep -q '^sleep' "$STUB_LOG" || false
}
@test "AP2: install_rke2's MetalLB step uses the retry" {
  [[ "$(declare -f helm_install_metallb)" == *'apply_metallb_config "$WORKING_DIR/ap-utilities/helm/metallb/metallb-config.yaml"'* ]]
}
@test "AP2: a setting that isn't a number falls back to the default" {
  kubectl_fails 0
  METALLB_APPLY_TRIES=abc METALLB_APPLY_WAIT=-1
  apply_metallb_config "$CONF" >/dev/null
  [ "$METALLB_APPLY_TRIES" = 12 ]
  [ "$METALLB_APPLY_WAIT" = 10 ]
}
