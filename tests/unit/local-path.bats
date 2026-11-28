#!/usr/bin/env bats
# Spec 30, Amendment B: DAP on local-path storage.
# R4 (Q21): local-path on a single node only. D14: Prometheus follows the cluster's default class without 'longhorn'.
load ../helpers
setup() {
  setup_stubs
  load_script ap-tools
  INSTALL_LOCAL_PATH_PROVISIONER=true
  INSTALL_MODE=1; JOIN_MODE=0; INSTALL_TYPE=rke2; CLUSTER_TYPE=single-node
  user_set_prometheus_sc=""; PROMETHEUS_STORAGE_CLASS=longhorn
}
# cluster <default provisioner> <default class name> <node count> [longhorn]: a kubectl stub for that cluster
cluster() {
  local longhorn_rc=1
  [[ "${4:-}" == "longhorn" ]] && longhorn_rc=0
  stub kubectl "case \"\$*\" in
  'get storageclass longhorn') exit $longhorn_rc ;;
  *'{.provisioner}'*) [ -n '$1' ] && echo '$1' ;;
  *'{.metadata.name}'*) [ -n '$2' ] && echo '$2' ;;
  'get nodes --no-headers') for i in \$(seq 1 $3); do echo \"node\$i Ready\"; done ;;
esac
exit 0"
}

@test "R4: 'join' with local-path is refused before anything changes" {
  INSTALL_MODE=0; JOIN_MODE=1; INSTALL_TYPE=""
  run local_path_single_node_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"'join' can't be used with INSTALL_LOCAL_PATH_PROVISIONER=true. Nothing has been changed."* ]]
  [[ "$output" == *"single node only"* ]]
}
@test "R4: 'install rke2' with CLUSTER_TYPE=multi-node and local-path is refused" {
  CLUSTER_TYPE=multi-node
  run local_path_single_node_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"'install rke2' with CLUSTER_TYPE=multi-node can't be used"* ]]
}
@test "R4: a single-node local-path install goes on" {
  run local_path_single_node_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
@test "R4: Longhorn on multi-node and join is untouched" {
  INSTALL_LOCAL_PATH_PROVISIONER=false; CLUSTER_TYPE=multi-node
  run local_path_single_node_check
  [ "$status" -eq 0 ]
  JOIN_MODE=1; INSTALL_MODE=0
  run local_path_single_node_check
  [ "$status" -eq 0 ]
}
@test "R4: other commands with local-path set are untouched (monitoring, velero, ap-bundle on one node)" {
  for t in monitoring velero ap-bundle ddpc-bundle; do
    INSTALL_TYPE=$t CLUSTER_TYPE=multi-node run local_path_single_node_check
    [ "$status" -eq 0 ]
  done
}
@test "R4: 'install ap-bundle' refuses a two-node cluster whose default class is local-path" {
  cluster rancher.io/local-path local-path 2
  run local_path_cluster_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"this cluster has 2 nodes, and its default StorageClass is local-path. Nothing has been changed."* ]]
}
@test "R4: 'install ap-bundle' on one local-path node goes on" {
  cluster rancher.io/local-path local-path 1
  run local_path_cluster_check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
@test "R4: 'install ap-bundle' on three Longhorn nodes goes on, without counting nodes" {
  cluster driver.longhorn.io longhorn 3 longhorn
  run local_path_cluster_check
  [ "$status" -eq 0 ]
  ! called "kubectl get nodes"
}
@test "D14: no 'longhorn' class and nothing set: Prometheus gets the cluster's default" {
  cluster rancher.io/local-path local-path 1
  resolve_prometheus_storage_class >/dev/null
  [ "$PROMETHEUS_STORAGE_CLASS" = local-path ]
  PROMETHEUS_STORAGE_CLASS=longhorn
  run resolve_prometheus_storage_class
  [[ "$output" == *"No 'longhorn' StorageClass: Prometheus uses the cluster's default, 'local-path'."* ]]
}
@test "D14: a 'longhorn' class keeps the default" {
  cluster driver.longhorn.io longhorn 1 longhorn
  resolve_prometheus_storage_class
  [ "$PROMETHEUS_STORAGE_CLASS" = longhorn ]
}
@test "D14: a class you set is passed as it is, and the cluster isn't asked" {
  user_set_prometheus_sc=x; PROMETHEUS_STORAGE_CLASS=fast-ssd
  cluster rancher.io/local-path local-path 1
  resolve_prometheus_storage_class
  [ "$PROMETHEUS_STORAGE_CLASS" = fast-ssd ]
  ! called kubectl
}
@test "D14: setting PROMETHEUS_STORAGE_CLASS=longhorn yourself keeps it, as before" {
  user_set_prometheus_sc=x
  cluster rancher.io/local-path local-path 1
  resolve_prometheus_storage_class
  [ "$PROMETHEUS_STORAGE_CLASS" = longhorn ]
}
@test "D14: no default class either: unchanged, and rke2-installer's own warning stays" {
  cluster "" "" 1
  run resolve_prometheus_storage_class
  [ -z "$output" ]
  resolve_prometheus_storage_class
  [ "$PROMETHEUS_STORAGE_CLASS" = longhorn ]
}
@test "D14: an unset PROMETHEUS_STORAGE_CLASS counts as unset; one from the environment counts as set" {
  run env -u PROMETHEUS_STORAGE_CLASS bash -c 'source "$1" >/dev/null 2>&1; echo "[$user_set_prometheus_sc] $PROMETHEUS_STORAGE_CLASS"' _ "$BATS_TEST_DIRNAME/../../ap-tools"
  [ "$output" = "[] longhorn" ]
  run env PROMETHEUS_STORAGE_CLASS=fast-ssd bash -c 'source "$1" >/dev/null 2>&1; echo "[$user_set_prometheus_sc] $PROMETHEUS_STORAGE_CLASS"' _ "$BATS_TEST_DIRNAME/../../ap-tools"
  [ "$output" = "[x] fast-ssd" ]
}
