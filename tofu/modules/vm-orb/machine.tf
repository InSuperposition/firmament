resource "orbstack_machine" "this" {
  name  = var.name
  image = var.image
}

# cpu/memory/disk limits are not declared here: orbstack_machine has no
# resource-limit arguments, and the provider's app-wide orbstack_config
# resource reports an apply-time error on every apply regardless of
# whether the underlying change succeeds.
#
# arch and username are left unset: OrbStack picks the architecture and the
# default user of the host it runs on.
