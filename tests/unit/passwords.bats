#!/usr/bin/env bats
# Spec 21 in ap-tools: the registry password reaches every sub-tool whole (AP4), the command block it writes for Dell's
# installer survives being pasted into an interactive shell (AP5), inputs.env takes any password in its documented form
# and a broken one stops the run (AP6), and rke2's bin directory follows RKE2_DATA (AP9). Every test password is used,
# and the bytes that arrive are compared.
load ../helpers
load ../vectors
setup() {
  load_script ap-tools
  setup_stubs
  load_vectors
  base_dir=$STUB_DIR
  WORKING_DIR="$STUB_DIR/work"
  AIR_GAPPED_MODE=0
  fetch_subtool() { :; }
  rke2_installer_check() { :; }
  image_pull_push_check() { :; }
  generate_images_file() { :; }
  # A file a glob in the password could match, where the sub-tools run
  mkdir -p "$WORKING_DIR/rke2" "$WORKING_DIR/ap-utilities/swfs" "$WORKING_DIR/ap-utilities/images"
  touch "$WORKING_DIR/rke2/Aa1-glob-bait" "$WORKING_DIR/ap-utilities/swfs/Aa1 x"
}
# fake <path>: a sub-tool that records each argument it gets, NUL-separated, in <path>.args
fake() {
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/bash\nprintf "%%s\\0" "$@" > "$0.args"\n' > "$1"
  chmod +x "$1"
}
# args_of <path>: the arguments the fake got, one per line (none of the test passwords has a newline)
args_of() { tr '\0' '\n' < "$1.args"; }
# arg_after <path> <arg> <n>: the nth argument after <arg>
arg_after() { args_of "$1" | awk -v a="$2" -v n="$3" 'f && ++i == n {print; exit} $0 == a {f = 1}'; }

@test "AP4: build_command_syntax keeps the registry password whole in every mode that sends it" {
  local n key
  run_debug() { "$@"; }
  REGISTRY_INFO=reg.example:443 REG_USER='robot$ci' TLS_SAN=api.example JOIN_SERVER_FQDN=s1.example JOIN_TOKEN=K10abc::server:xyz
  for n in "${VEC_NAMES[@]}"; do
    REG_PASS=${VEC[$n]}
    for key in 1110000 1111000 1010000 1011000 0110000 0010110 0010101 0011101; do
      INSTALL_MODE=${key:0:1} PUSH_MODE=${key:1:1} REGISTRY_MODE=${key:2:1} TLS_SAN_MODE=${key:3:1} JOIN_MODE=${key:4:1}
      JOIN_TYPE=""; [[ ${key:5:1} == 1 ]] && JOIN_TYPE=agent; [[ ${key:6:1} == 1 ]] && JOIN_TYPE=server
      build_command_syntax >/dev/null
      local i=0 found=0
      for ((i = 0; i < ${#RKE2_CMD_ARGS[@]}; i++)); do
        if [[ "${RKE2_CMD_ARGS[i]}" == -registry ]]; then
          [ "${RKE2_CMD_ARGS[i+1]}" = reg.example:443 ]
          [ "${RKE2_CMD_ARGS[i+2]}" = 'robot$ci' ]
          [ "${RKE2_CMD_ARGS[i+3]}" = "${VEC[$n]}" ]
          found=1
        fi
      done
      [ "$found" = 1 ] || { echo "no -registry in mode $key"; false; }
    done
  done
}
@test "AP4: the printed command masks the password" {
  run_debug() { "$@"; }
  INSTALL_MODE=1 PUSH_MODE=1 REGISTRY_MODE=1 TLS_SAN_MODE=0 JOIN_MODE=0 JOIN_TYPE="" REGISTRY_INFO=r:443 REG_USER=u
  REG_PASS=${VEC[full]}
  run build_command_syntax
  [[ "$output" == *"parsed command args: install push -registry r:443 u ********"* ]]
  [[ "$output" != *"${VEC[full]}"* ]]
}
@test "AP4: rke2's install, upgrade and Velero, SeaweedFS and the add-on push each get the password as one argument" {
  local n
  # run_debug does nothing here, so run_install_join_push's own add-on push is left to the call below
  run_debug() { :; }; check_rke2_service_running() { :; }; set_longhorn_packages() { :; }; install_packages_check() { :; }
  fake "$WORKING_DIR/ap-utilities/packages/install_packages.sh"
  fake "$WORKING_DIR/rke2/rke2_installer.sh"
  fake "$WORKING_DIR/ap-utilities/swfs/install-seaweedfs"
  fake "$WORKING_DIR/ap-utilities/images/image_pull_push.sh"
  REGISTRY_INFO=reg.example:443 REG_USER=robot INSTALL_TYPE=push-only UPGRADE_TYPE=cluster UPGRADE_VERSION=v1.34.5+rke2r1
  INSTALL_MODE=1 JOIN_MODE=0 PUSH_MODE=1 REGISTRY_MODE=1
  for n in "${VEC_NAMES[@]}"; do
    echo "vector: $n"
    REG_PASS=${VEC[$n]}
    RKE2_CMD_ARGS=(install push -registry "$REGISTRY_INFO" "$REG_USER" "$REG_PASS")
    run_install_join_push >/dev/null
    [ "$(arg_after "$WORKING_DIR/rke2/rke2_installer.sh" -registry 3)" = "$REG_PASS" ]
    run_upgrade_rke2 >/dev/null
    [ "$(arg_after "$WORKING_DIR/rke2/rke2_installer.sh" -registry 3)" = "$REG_PASS" ]
    run_install_velero >/dev/null
    [ "$(arg_after "$WORKING_DIR/rke2/rke2_installer.sh" -registry 3)" = "$REG_PASS" ]
    run_install_swfs >/dev/null
    [ "$(arg_after "$WORKING_DIR/ap-utilities/swfs/install-seaweedfs" -registry 3)" = "$REG_PASS" ]
    push_addon_images >/dev/null
    [ "$(arg_after "$WORKING_DIR/ap-utilities/images/image_pull_push.sh" push 3)" = "$REG_PASS" ]
  done
}
@test "AP4: with no registry, nothing extra is sent" {
  run_debug() { :; }; check_rke2_service_running() { :; }; set_longhorn_packages() { :; }; install_packages_check() { :; }
  enable_iscsid() { :; }
  fake "$WORKING_DIR/ap-utilities/packages/install_packages.sh"
  fake "$WORKING_DIR/rke2/rke2_installer.sh"
  INSTALL_MODE=1 JOIN_MODE=0 PUSH_MODE=0 REGISTRY_MODE=0 INSTALL_TYPE=push-only RKE2_CMD_ARGS=(install)
  run_install_join_push >/dev/null
  [ "$(args_of "$WORKING_DIR/rke2/rke2_installer.sh")" = install ]
}

# The DAP command block, written by runtime_outputs, then pasted into an interactive bash, as the file says to do.
# Dell's install-upgrade.sh is a fake that records its arguments; sudo runs its arguments.
paste_block() { # paste_block <cmd file> -> the KEY=value arguments the fake got, NUL-separated, in $T/argv
  T=$(mktemp -d)
  printf '#!/bin/bash\nprintf "%%s\\0" "$@" > "%s/argv"\n' "$T" > "$WORKING_DIR/bundle/install-upgrade.sh"
  chmod +x "$WORKING_DIR/bundle/install-upgrade.sh"
  stub sudo '"$@"'
  # An earlier line, so that !x and !! have something to find, as in a real terminal
  { echo 'echo previous-command >/dev/null'; sed -n '/^----$/,/^----$/p' "$1" | sed '1d;$d'; } > "$T/in.sh"
  HISTFILE=/dev/null bash --norc --noprofile -i < "$T/in.sh" > "$T/out" 2> "$T/err"
}
dap_outputs() {
  INSTALL_TYPE=ap-bundle ORCHESTRATOR_FQDN=o.example PORTAL_FQDN=p.example PORTAL_COOKIE_DOMAIN=example
  REGISTRY_INFO=reg.example:443 REGISTRY_PROJECT_NAME=dell-automation REG_CERT_FILE_PATH=/etc/x/ca.crt
  SKIP_IMAGES_LOADER=false IMAGE_LOADER_THREAD_COUNT=4 ORCHESTRATOR_NAMESPACE=dell-orchestrator PORTAL_NAMESPACE=dell-portal
  PORTAL_INGRESS_CLASS_NAME=haproxy ORG_NAME="Org \$x" ORG_DESC='it'"'"'s "ours"' FIRST_NAME=A LAST_NAME=B USERNAME=administrator
  EMAIL=a@example.com ntp_message=""
  mkdir -p "$WORKING_DIR/bundle"
  state_set() { :; }
  runtime_outputs
}
@test "AP5: pasted into an interactive shell, the DAP command gives Dell's installer each test password exactly" {
  local n got
  REG_USER='robot$ci'
  for n in "${VEC_NAMES[@]}" bang1 bang2; do
    case $n in bang1) REG_PASS='Aa1!pass';; bang2) REG_PASS='Aa1!!x!$y';; *) REG_PASS=${VEC[$n]};; esac
    echo "vector: $n"
    dap_outputs >/dev/null
    paste_block "$base_dir/ap-install-upgrade-cmd.txt"
    got=$(tr '\0' '\n' < "$T/argv" | sed -n 's/^IMAGE_REG_PASSWORD=//p')
    [ "$got" = "$REG_PASS" ] || { cat "$T/err"; false; }
    [ "$(tr '\0' '\n' < "$T/argv" | sed -n 's/^IMAGE_REG_USERNAME=//p')" = 'robot$ci' ]
    [ "$(tr '\0' '\n' < "$T/argv" | sed -n 's/^ORG_DESC=//p')" = 'it'"'"'s "ours"' ]
  done
}
@test "AP5: the printed command block masks the password in its quoted form, and the file is 0600" {
  REG_USER=robot REG_PASS="Aa1'q!x"
  run dap_outputs
  [[ "$output" != *"Aa1'\\''q!x"* && "$output" != *"Aa1'q!x"* ]]
  [[ "$output" == *"IMAGE_REG_PASSWORD='********'"* ]]
  [ "$(stat -c %a "$base_dir/ap-install-upgrade-cmd.txt")" = 600 ]
}

# inputs.env: the documented form for a password, VAR=${VAR:-'value'}, read by ap-tools as it starts
start_with_env() { # start_with_env <inputs.env> [VAR=value ...]: ap-tools' own start, then SWFS_HARBOR_PASS
  local f=$1; shift
  sed -n '1,/^# Track which Harbor-scoped/p' "$BATS_TEST_DIRNAME/../../ap-tools" > "$BATS_TEST_TMPDIR/head.sh"
  printf '%s\n' 'printf "%s" "$SWFS_HARBOR_PASS"' >> "$BATS_TEST_TMPDIR/head.sh"
  env "$@" AP_TOOLS_ENV_FILE="$f" bash "$BATS_TEST_TMPDIR/head.sh"
}
@test "AP6: every test password in inputs.env's documented form is read exactly, and a command-line value still wins" {
  local n v f
  f=$BATS_TEST_TMPDIR/inputs.env
  for n in "${VEC_NAMES[@]}"; do
    v=${VEC[$n]}
    printf "SWFS_HARBOR_PASS=\${SWFS_HARBOR_PASS:-'%s'}\n" "${v//\'/\'\\\'\'}" > "$f"; chmod 600 "$f"
    run start_with_env "$f"
    [ "$status" -eq 0 ]
    [ "${output##*$'\n'}" = "$v" ] || { echo "got <${output##*$'\n'}> want <$v>"; false; }
    run start_with_env "$f" SWFS_HARBOR_PASS=from-cli
    [ "${output##*$'\n'}" = from-cli ]
  done
}
@test "AP6: an inputs.env bash can't read stops the run, naming the file, before anything is set" {
  f=$BATS_TEST_TMPDIR/inputs.env
  printf '%s\n' 'SWFS_HARBOR_PASS="${SWFS_HARBOR_PASS:-Aa1'"'"'x}"' 'HOST_FQDN="host.example"' 'DEBUG="${DEBUG:-0}' > "$f"; chmod 600 "$f"
  run start_with_env "$f"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$f can't be read as shell"* && "$output" == *"Nothing has been changed"* ]]
  [[ "$output" == *"inputs.env.example"* ]]
}
@test "AP6: the example's password lines use the single-quoted form, and the example itself reads" {
  ex="$BATS_TEST_DIRNAME/../../inputs.env.example"
  bash -n "$ex"
  grep -qx "#SWFS_HARBOR_PASS=\${SWFS_HARBOR_PASS:-'changeme'}.*" "$ex"
  ! grep -E '^#?(SWFS_HARBOR_PASS|DNS_ADMIN_CURRENT_PASSWORD|VELERO_S3_ACCESS_KEY|VELERO_S3_SECRET_KEY)="' "$ex" || false
}

@test "AP9: rke2's bin directory follows RKE2_DATA, and default is rke2's own" {
  RKE2_DATA=default; [ "$(rke2_bin_dir)" = /var/lib/rancher/rke2/bin ]
  RKE2_DATA=""; [ "$(rke2_bin_dir)" = /var/lib/rancher/rke2/bin ]
  RKE2_DATA=/data/rke2; [ "$(rke2_bin_dir)" = /data/rke2/bin ]
  RKE2_DATA=/data/rke2//; [ "$(rke2_bin_dir)" = /data/rke2/bin ]
  ! grep -n '/var/lib/rancher/rke2/' "$BATS_TEST_DIRNAME/../../ap-tools" | grep -v 'd=/var/lib/rancher/rke2$' | grep -v '^\s*#' || false
}
@test "AP9: upgrade forwards RKE2_DATA, as install does" {
  fake "$WORKING_DIR/rke2/rke2_installer.sh"
  cat > "$WORKING_DIR/rke2/rke2_installer.sh" <<'F'
#!/bin/bash
echo "RKE2_DATA=$RKE2_DATA" > "$0.env"
F
  chmod +x "$WORKING_DIR/rke2/rke2_installer.sh"
  RKE2_DATA=/data/rke2 UPGRADE_TYPE=cluster UPGRADE_VERSION=v1 REGISTRY_MODE=0
  run_upgrade_rke2 >/dev/null
  grep -qx 'RKE2_DATA=/data/rke2' "$WORKING_DIR/rke2/rke2_installer.sh.env"
}
