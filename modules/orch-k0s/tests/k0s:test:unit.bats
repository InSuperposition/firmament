#!/usr/bin/env bats
load setup.bash

resource_after() {
  plan_json | jq -c '.resource_changes[] | select(.address == "k0sctl_config.this") | .change.after'
}

@test "plans connection values from the environment" {
  run resource_after
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec.host[0].ssh[0].address' <<<"$output")" = 127.0.0.1 ]
  [ "$(jq -r '.spec.host[0].ssh[0].user' <<<"$output")" = 'developer@firmament' ]
  [ "$(jq -r '.spec.host[0].ssh[0].port' <<<"$output")" = 32222 ]
  [ "$(jq -r '.spec.host[0].ssh[0].key_path' <<<"$output")" = /tmp/orbstack-test-key ]
  [ "$(jq -r '.spec.k0s.config' <<<"$output" | yq -r '.spec.api.externalAddress')" = firmament.orb.local ]
  [ "$(jq -r '.spec.k0s.config' <<<"$output" | yq -r '.spec.api.port')" = 6443 ]
}

@test "preserves the declarative cluster contract" {
  run resource_after
  [ "$status" -eq 0 ]
  [ "$(jq -r '.spec.host[0].role' <<<"$output")" = 'controller+worker' ]
  [ "$(jq -r '.spec.host[0].no_taints' <<<"$output")" = true ]
  [ "$(jq -r '.spec.k0s.version' <<<"$output")" = '1.36.4+k0s.0' ]
  config=$(jq -r '.spec.k0s.config' <<<"$output")
  [ "$(yq -r '.spec.network.provider' <<<"$config")" = custom ]
  [ "$(yq -r '.spec.network.podCIDR' <<<"$config")" = 10.244.0.0/16 ]
  [ "$(yq -r '.spec.network.serviceCIDR' <<<"$config")" = 10.96.0.0/12 ]
  [ "$(yq -r '.spec.network.kubeProxy.disabled' <<<"$config")" = true ]
}

@test "serves the API on the configured port" {
  run cluster_config -var='api_port=16443'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.api.port' <<<"$output")" = 16443 ]
}

@test "rejects an API port that is not a whole TCP port number" {
  local port
  for port in 0 65536 6443.5; do
    run tofu -chdir="$k0s_directory" plan -input=false \
      -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
      -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
      -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
      -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
      -var="api_address=$FIRMAMENT_K0S_API_ADDRESS" \
      -var="api_port=$port"
    [ "$status" -eq 1 ]
    [[ "$output" == *'invalid API port'* ]]
  done
}

@test "rejects changing kube_proxy_replacement after cluster creation" {
  local state="$BATS_TEST_ROOT/terraform.tfstate"
  tofu -chdir="$k0s_directory" apply -input=false -auto-approve -state="$state" \
    -target=terraform_data.kube_proxy_replacement_at_creation \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS" >/dev/null

  run plan_json -state="$state"
  [ "$status" -eq 0 ]

  run tofu -chdir="$k0s_directory" plan -input=false -state="$state" \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS" \
    -var='kube_proxy_replacement=false'
  [ "$status" -eq 1 ]
  [[ "$output" == *'kube_proxy_replacement is fixed at cluster creation'* ]]
}

@test "renders no extensions without Helm charts" {
  run cluster_config
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec | has("extensions")' <<<"$output")" = false ]
}

@test "runs kube-proxy when the CNI does not replace it" {
  run cluster_config -var='kube_proxy_replacement=false'
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.network.kubeProxy.disabled' <<<"$output")" = false ]
}

@test "renders Helm charts into the k0s Helm extension" {
  cat >"$BATS_TEST_ROOT/charts.tfvars.json" <<'JSON'
{
  "helm_charts": [
    {
      "repository": { "name": "example", "url": "https://charts.example.com" },
      "chart": {
        "name": "demo",
        "chartname": "example/demo",
        "version": "1.2.3",
        "namespace": "kube-system",
        "values": "replicas: 1\n"
      }
    }
  ]
}
JSON
  run cluster_config -var-file="$BATS_TEST_ROOT/charts.tfvars.json"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.extensions.helm.repositories[0].name' <<<"$output")" = example ]
  [ "$(yq -r '.spec.extensions.helm.repositories[0].url' <<<"$output")" = https://charts.example.com ]
  [ "$(yq -r '.spec.extensions.helm.charts[0].name' <<<"$output")" = demo ]
  [ "$(yq -r '.spec.extensions.helm.charts[0].chartname' <<<"$output")" = example/demo ]
  [ "$(yq -r '.spec.extensions.helm.charts[0].version' <<<"$output")" = 1.2.3 ]
  [ "$(yq -r '.spec.extensions.helm.charts[0].namespace' <<<"$output")" = kube-system ]
  [ "$(yq -r '.spec.extensions.helm.charts[0].values' <<<"$output" | yq -r '.replicas')" = 1 ]
  [ "$(yq -r '.spec.extensions.helm.charts[0].forceUpgrade' <<<"$output")" = true ]
}

@test "shares one repository between charts that come from it" {
  cat >"$BATS_TEST_ROOT/charts.tfvars.json" <<'JSON'
{
  "helm_charts": [
    {
      "repository": { "name": "example", "url": "https://charts.example.com" },
      "chart": { "name": "first", "chartname": "example/first", "version": "1.0.0", "namespace": "kube-system", "values": "" }
    },
    {
      "repository": { "name": "example", "url": "https://charts.example.com" },
      "chart": { "name": "second", "chartname": "example/second", "version": "2.0.0", "namespace": "default", "values": "" }
    }
  ]
}
JSON
  run cluster_config -var-file="$BATS_TEST_ROOT/charts.tfvars.json"
  [ "$status" -eq 0 ]
  [ "$(yq -r '.spec.extensions.helm.repositories | length' <<<"$output")" = 1 ]
  [ "$(yq -r '.spec.extensions.helm.charts | length' <<<"$output")" = 2 ]
  [ "$(yq -r '.spec.extensions.helm.charts[0].name' <<<"$output")" = first ]
  [ "$(yq -r '.spec.extensions.helm.charts[1].name' <<<"$output")" = second ]
  [ "$(yq -r '.spec.extensions.helm.charts[1].namespace' <<<"$output")" = default ]
}

@test "rejects one repository name pointing at two URLs" {
  cat >"$BATS_TEST_ROOT/charts.tfvars.json" <<'JSON'
{
  "helm_charts": [
    {
      "repository": { "name": "example", "url": "https://a.example.com" },
      "chart": { "name": "first", "chartname": "example/first", "version": "1.0.0", "namespace": "kube-system", "values": "" }
    },
    {
      "repository": { "name": "example", "url": "https://b.example.com" },
      "chart": { "name": "second", "chartname": "example/second", "version": "1.0.0", "namespace": "kube-system", "values": "" }
    }
  ]
}
JSON
  run tofu -chdir="$k0s_directory" plan -input=false \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS" \
    -var-file="$BATS_TEST_ROOT/charts.tfvars.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *'each Helm repository name must point at one URL'* ]]
}

@test "rejects two Helm charts with the same name" {
  cat >"$BATS_TEST_ROOT/charts.tfvars.json" <<'JSON'
{
  "helm_charts": [
    {
      "repository": { "name": "example", "url": "https://charts.example.com" },
      "chart": { "name": "demo", "chartname": "example/demo", "version": "1.0.0", "namespace": "kube-system", "values": "" }
    },
    {
      "repository": { "name": "example", "url": "https://charts.example.com" },
      "chart": { "name": "demo", "chartname": "example/demo", "version": "1.0.0", "namespace": "default", "values": "" }
    }
  ]
}
JSON
  run tofu -chdir="$k0s_directory" plan -input=false \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS" \
    -var-file="$BATS_TEST_ROOT/charts.tfvars.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *'each Helm chart name must be unique'* ]]
}

@test "rejects Helm chart values that are not valid YAML" {
  cat >"$BATS_TEST_ROOT/charts.tfvars.json" <<'JSON'
{
  "helm_charts": [
    {
      "repository": { "name": "example", "url": "https://charts.example.com" },
      "chart": { "name": "demo", "chartname": "example/demo", "version": "1.0.0", "namespace": "kube-system", "values": "replicas: [1\n" }
    }
  ]
}
JSON
  run tofu -chdir="$k0s_directory" plan -input=false \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS" \
    -var-file="$BATS_TEST_ROOT/charts.tfvars.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *'values must be valid YAML'* ]]
}

@test "rejects a Helm chart without values" {
  cat >"$BATS_TEST_ROOT/charts.tfvars.json" <<'JSON'
{
  "helm_charts": [
    {
      "repository": { "name": "example", "url": "https://charts.example.com" },
      "chart": { "name": "demo", "chartname": "example/demo", "version": "1.2.3", "namespace": "kube-system" }
    }
  ]
}
JSON
  run tofu -chdir="$k0s_directory" plan -input=false \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS" \
    -var-file="$BATS_TEST_ROOT/charts.tfvars.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *var.helm_charts* ]]
  [[ "$output" == *'"values"'* ]]
}

@test "requires every connection input" {
  unset FIRMAMENT_K0S_SSH_KEY
  run tofu -chdir="$k0s_directory" plan -input=false \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *ssh_key_path* ]]
}

@test "rejects unsafe connection values" {
  export FIRMAMENT_K0S_SSH_ADDRESS='host with spaces'
  run tofu -chdir="$k0s_directory" plan -input=false \
    -var="ssh_address=$FIRMAMENT_K0S_SSH_ADDRESS" \
    -var="ssh_user=$FIRMAMENT_K0S_SSH_USER" \
    -var="ssh_port=$FIRMAMENT_K0S_SSH_PORT" \
    -var="ssh_key_path=$FIRMAMENT_K0S_SSH_KEY" \
    -var="api_address=$FIRMAMENT_K0S_API_ADDRESS"
  [ "$status" -eq 1 ]
  [[ "$output" == *'invalid SSH address'* ]]
}
