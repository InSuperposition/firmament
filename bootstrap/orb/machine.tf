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

# cpu/memory/disk limits are not declared here: orbstack_machine has no
# resource-limit arguments, and the provider's app-wide orbstack_config
# resource reports an apply-time error on every apply regardless of
# whether the underlying change succeeds.
