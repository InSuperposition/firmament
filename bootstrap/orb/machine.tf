locals {
  name     = "firmament"
  image    = "ubuntu:resolute"
  arch     = "arm64"
  username = "tensor"
}

resource "orbstack_machine" "firmament" {
  name     = local.name
  image    = local.image
  arch     = local.arch
  username = local.username
}

# cpu/memory/disk limits are intentionally NOT declared here. The
# underlying `orb` CLI supports real per-machine limits
# (`orb config set machine.<name>.cpu|memory_mib|disk_bytes <n>`, verified
# working), but the provider exposes none of that: `orbstack_machine` has
# no resource-limit arguments, and `orbstack_config` is app-wide only —
# and even that app-wide resource throws "Provider produced inconsistent
# result after apply" on every apply (verified: the underlying orb config
# change DOES take effect despite the error, but a task built on this
# would report failure on every successful run). See
# FIRMAMENT_FINDINGS.md in the opentofu-provider-orbstack fork.
