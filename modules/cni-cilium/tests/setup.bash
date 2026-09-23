setup() {
  export BATS_TEST_ROOT="$BATS_TEST_TMPDIR/cilium"
  mkdir -p "$BATS_TEST_ROOT"

  root_directory=$(cd -- "$BATS_TEST_DIRNAME/../../.." && pwd)
  module_directory="$root_directory/modules/cni-cilium"

  tofu -chdir="$module_directory" init -backend=false -input=false -reconfigure >/dev/null
}

helm_chart() {
  local plan="$BATS_TEST_ROOT/plan.tfplan"
  tofu -chdir="$module_directory" plan -input=false -out="$plan" \
    -var='api_host=firmament.orb.local' \
    -var='kube_proxy_replacement=true' "$@" >/dev/null
  tofu -chdir="$module_directory" show -json "$plan" | jq -c '.planned_values.outputs.helm_chart.value'
}

chart_values() {
  helm_chart "$@" | jq -r '.chart.values'
}
