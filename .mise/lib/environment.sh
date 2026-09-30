# shellcheck shell=bash
# What an environment is and deploys: its directory, the modules its Flux
# build lists and the selection of them a task runs, and the facts a live
# run records.

# Prints the OpenTofu root directory of an environment, or fails when the
# environment does not exist.
environment_directory() {
  local environment="$1"
  local directory="${MISE_PROJECT_ROOT:?run this through mise}/environments/$environment"
  if [[ ! -d "$directory" ]]; then
    fail "unknown environment '$environment': $directory does not exist"
    return
  fi
  printf '%s\n' "$directory"
}

# Prints the directory of each component an environment's Flux build lists,
# one per line, or nothing for an environment without a Flux build. Only
# directories are components; a resource file the build lists is not.
deployed_components() {
  local directory resources resource
  directory=$(environment_directory "$1") || return
  [[ -f "$directory/flux/kustomization.yaml" ]] || return 0
  resources=$(yq -r '.resources[]' "$directory/flux/kustomization.yaml") || return
  while IFS= read -r resource; do
    if [[ -n "$resource" && -d "$directory/flux/$resource" ]]; then
      (cd "$directory/flux/$resource" && pwd)
    fi
  done <<<"$resources"
}

# Prints the module name of a component directory: its name without the
# role prefix, so packages/cni-cilium is the module cilium. The module
# name is also the noun of the component's tasks (cilium:verify).
module_name() {
  local component="${1##*/}"
  printf '%s\n' "${component#*-}"
}

# Fails unless every name in a comma-separated module list is a module the
# environment deploys, naming the modules it does deploy. An empty list
# selects every module, and "none" selects no module.
check_modules() {
  local environment="$1" only="$2" components deployed="" component name
  local -a names
  components=$(deployed_components "$environment") || return
  while IFS= read -r component; do
    [[ -n "$component" ]] && deployed+="$(module_name "$component") "
  done <<<"$components"
  [[ "$only" == none ]] && return 0
  IFS=, read -ra names <<<"$only"
  for name in "${names[@]}"; do
    if [[ " $deployed" != *" $name "* ]]; then
      fail "unknown module '$name' for environment '$environment'; choose from: ${deployed% }"
      return
    fi
  done
}

# Succeeds when a module is selected by a comma-separated list; an empty
# list selects every module, and "none" selects no module.
module_selected() {
  local name="$1" only="$2"
  [[ -z "$only" || ",$only," == *",$name,"* ]]
}

# Prints the modules a branch changed, as a module list for --only: a path
# under packages/<name>/ selects that module when the environment deploys
# it, and a component it does not deploy changes nothing here. A change to
# any other file, except Markdown, can affect every module, so it prints an
# empty list (every module). With no such change it prints "none". Changes
# are counted from where the branch left origin/main, uncommitted and
# untracked files included, since the suites run from the checkout.
changed_modules() {
  local environment="$1" root="${MISE_PROJECT_ROOT:?}" base paths components component path
  local deployed="" selected=""
  base=$(git -C "$root" merge-base origin/main HEAD) ||
    fail "cannot find where this branch left origin/main; fetch origin first" || return
  paths=$(
    git -C "$root" diff --name-only "$base" &&
      git -C "$root" ls-files --others --exclude-standard
  ) || return
  components=$(deployed_components "$environment") || return
  while IFS= read -r component; do
    [[ -n "$component" ]] && deployed+=" ${component##*/}"
  done <<<"$components"
  while IFS= read -r path; do
    case "$path" in
    "" | *.md) ;;
    packages/*/*)
      component="${path#packages/}"
      component="${component%%/*}"
      if [[ " $deployed " == *" $component "* && ",$selected," != *",$(module_name "$component"),"* ]]; then
        selected+="${selected:+,}$(module_name "$component")"
      fi
      ;;
    *)
      return 0
      ;;
    esac
  done <<<"$paths"
  printf '%s\n' "${selected:-none}"
}

# Prints the module list a task runs from its --only and --changed flags:
# the --only list as given, the modules --changed finds, or an empty list
# (every module) when neither is set. The two flags cannot be combined.
module_selection() {
  local environment="$1" only="$2" changed="$3"
  if [[ -n "$only" && "$changed" == true ]]; then
    fail "--only and --changed cannot be combined"
    return
  fi
  if [[ "$changed" == true ]]; then
    changed_modules "$environment"
    return
  fi
  check_modules "$environment" "$only" || return
  printf '%s\n' "$only"
}

# Prints the Cilium connectivity test patterns that the chosen modules list
# in tests/conformance, one --test regular expression per line, without
# blank lines and # comments. An empty module list chooses every module.
conformance_patterns() {
  local environment="$1" only="${2:-}" components component
  check_modules "$environment" "$only" || return
  components=$(deployed_components "$environment") || return
  while IFS= read -r component; do
    if [[ -n "$component" && -f "$component/tests/conformance" ]] &&
      module_selected "$(module_name "$component")" "$only"; then
      grep -Ev '^[[:space:]]*(#|$)' "$component/tests/conformance" || true
    fi
  done <<<"$components"
}

# Prints a short name for an env:e2e step from its command: the task a
# `mise ... run` call runs, otherwise the command's first word.
step_label() {
  local seen_run=false argument
  for argument in "$@"; do
    if [[ "$seen_run" == true && "$argument" != -* ]]; then
      printf '%s\n' "$argument"
      return
    fi
    [[ "$argument" == run ]] && seen_run=true
  done
  printf '%s\n' "$1"
}

# Prints the time each step took, from a file of "<label><TAB><seconds>"
# lines, next to the change since an earlier file of the same form. A step
# the earlier file lacks is marked new; a missing earlier file marks every
# step new.
step_time_report() {
  local previous="$1" current="$2"
  [[ -f "$previous" ]] || previous=/dev/null
  awk -F '\t' '
    FILENAME == ARGV[1] { before[$1] = $2; next }
    {
      if ($1 in before) {
        change = $2 - before[$1]
        note = sprintf("%+d s", change)
      } else {
        note = "new"
      }
      printf "  %-24s %5d s  (%s)\n", $1, $2, note
      total += $2
    }
    END { printf "  %-24s %5d s\n", "total", total }
  ' "$previous" "$current"
}

# Prints the OrbStack and guest kernel versions an environment's machine
# runs on. Both sit outside what this repository pins, so live runs record
# them.
platform_versions() {
  local machine
  machine=$(environment_output "$1" machine_name) || return
  printf 'OrbStack: %s\n' "$(orb version | head -n 1)"
  printf 'kernel: %s\n' "$(orb -m "$machine" uname -r)"
}

# Prints one sorted "namespace/pod uid container-ids restarts" line for each
# pod an identity list selects. Each list line is "<namespace> <selector>".
# Two snapshots that match mean the same pods kept running, with no
# container restarted or replaced. A line that selects no pod fails, since
# two empty snapshots would match without checking anything.
workload_identities() {
  local kubeconfig="$1" list="$2" namespace selector identities
  while read -r namespace selector; do
    [[ -n "$namespace" && "$namespace" != \#* ]] || continue
    identities=$(kubectl --kubeconfig "$kubeconfig" -n "$namespace" get pods -l "$selector" -o json |
      jq -r '.items[] | [
          .metadata.namespace + "/" + .metadata.name,
          .metadata.uid,
          ([.status.containerStatuses[]?.containerID] | sort | join(",")),
          ([.status.containerStatuses[]?.restartCount] | add // 0)
        ] | @tsv') || return
    if [[ -z "$identities" ]]; then
      fail "$namespace $selector selects no pod"
      return
    fi
    printf '%s\n' "$identities"
  done <"$list" | sort
}

# Fails when the environment's cluster has Helm charts that k0s installs.
# k0s uninstalls a chart once it leaves its configuration, and this
# configuration installs none, so applying over such a cluster would remove
# its Cilium. Passes when the state records no cluster; fails when the
# state cannot be read or a recorded cluster cannot answer, since either
# says nothing about its charts. Whether a cluster is recorded comes from
# the state's resources, not its outputs: a targeted destroy such as
# orb:destroy removes the cluster but leaves the outputs as they were.
refuse_k0s_charts() {
  local kubeconfig resources charts errors error_text
  kubeconfig=$(environment_output_or_empty "$1" kubeconfig_path) || return
  if [[ -z "$kubeconfig" ]]; then
    return 0
  fi
  resources=$(tofu_in_environment "$1" state list) || return
  if ! grep -qx 'module\.orch_k0s\.k0sctl_config\.this' <<<"$resources"; then
    return 0
  fi
  errors=$(mktemp)
  if ! charts=$(kubectl --kubeconfig "$kubeconfig" get charts.helm.k0sproject.io -A -o name --request-timeout=10s 2>"$errors"); then
    error_text=$(cat "$errors")
    rm -f "$errors"
    fail "cannot tell whether k0s installs Helm charts on this cluster:"$'\n'"$error_text"$'\n'"Start the machine, or rebuild it: mise run --yes env:destroy $1, then mise run env:apply $1"
    return
  fi
  rm -f "$errors"
  if [[ -n "$charts" ]]; then
    fail "k0s still installs Helm charts on this cluster, and applying would uninstall them:"$'\n'"$charts"$'\n'"Rebuild it instead: mise run --yes env:destroy $1, then mise run env:apply $1"
  fi
}

# Destroys an environment: the cluster its OpenTofu root recorded, then the
# machines environment.yaml lists, then its claim. The root reads the
# machine-hosts file, so a state that still records a cluster without that
# file fails instead of leaving the state pointing at deleted machines.
destroy_environment() {
  local environment="$1" state
  state=$(state_directory "$environment") || return
  init_environment "$environment" || return
  if [[ -f "$state/machine-hosts.yaml" ]]; then
    # The bootstrap root is left alone: its objects live in the cluster and
    # go with the machines, and the next apply's refresh drops them.
    tofu_in_environment "$environment" destroy -input=false -auto-approve || return
  elif [[ -n "$(tofu_in_environment "$environment" state list)" ]]; then
    fail "the state of '$environment' records a cluster, but $state/machine-hosts.yaml is gone; run mise run orb:apply $environment to write it again, then destroy"
    return
  fi
  destroy_machines "$environment" || return
  release_environment "$environment"
}
