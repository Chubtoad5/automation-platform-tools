#!/usr/bin/env bats
# Spec 21's static check (tests/secret-lint.py, the same in every changed repo): no secret unquoted, or given to echo,
# eval, sed or a Helm --set. The second test shows the check can fail.
SCRIPTS=(ap-tools)
LINT="$BATS_TEST_DIRNAME/../secret-lint.py"
@test "secret-lint: this repo's scripts pass" {
  local s files=()
  for s in "${SCRIPTS[@]}"; do files+=("$BATS_TEST_DIRNAME/../../$s"); done
  run python3 "$LINT" "${files[@]}"
  echo "$output"
  [ "$status" -eq 0 ]
}
@test "secret-lint finds each kind of problem, and nothing in the safe forms" {
  f=$BATS_TEST_TMPDIR/bad.sh
  cat > "$f" <<'SCRIPT'
#!/bin/bash
REG_PASS=$1
tool push $REG_PASS
echo "$REG_PASS" | other
eval "x=$REG_PASS"
sed -i "s/old/$REG_PASS/" file
helm install x --set "pw=$REG_PASS"
tool push "$REG_PASS"
printf '%s\n' "$REG_PASS" | other
echo "REG_PASS: ${REG_PASS:+********}"
[[ -n "$REG_PASS" ]] && echo set
PASS_FILE=/tmp/x; cat $PASS_FILE
tool $REG_PASS # secret-lint: ok a fixture line
cat > out <<EOT
echo $REG_PASS
EOT
SCRIPT
  run python3 "$LINT" "$f"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *":3: unquoted REG_PASS"* ]]
  [[ "$output" == *":4: echo REG_PASS"* ]]
  [[ "$output" == *":5: eval REG_PASS"* ]]
  [[ "$output" == *":6: sed REG_PASS"* ]]
  [[ "$output" == *":7: --set REG_PASS"* ]]
  [ "$(grep -c ": \(unquoted\|echo\|eval\|sed\|--set\) " <<< "$output")" -eq 5 ]
}
