# Spec 21's test passwords (tests/password-vectors.txt), the same in every changed repo.
# load_vectors: fills VEC_NAMES (in file order) and VEC[name]=value. A value keeps its spaces at either end.
# shellcheck disable=SC2034  # VEC and VEC_NAMES are for the tests that load this file
declare -gA VEC=()
declare -ga VEC_NAMES=()
load_vectors() {
  local file=${1:-$BATS_TEST_DIRNAME/../password-vectors.txt} line name value
  VEC=(); VEC_NAMES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    name=${line%%$'\t'*}
    value=${line#*$'\t'}
    VEC[$name]=$value
    VEC_NAMES+=("$name")
  done < "$file"
}
