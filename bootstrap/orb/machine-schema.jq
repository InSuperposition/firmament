# Positive whole-number limits prevent invalid native creation arguments.
def positive_integer:
  type == "number" and . > 0 and floor == .;

def valid_target:
  type == "object"
  and (.name | type == "string" and test("^[a-z][a-z0-9-]*$"))
  and (.image.distro == "ubuntu")
  and (.image.version == "resolute")
  and (.image.arch == "arm64")
  and (.cpus | positive_integer)
  and (.memory_mib | positive_integer)
  and (.disk_gib | positive_integer);

# Validate OrbStack's response against the declared machine contract.
def matches_target($expected):
  .record as $machine
  | ($machine | type == "object")
    and ($machine.id | type == "string" and length > 0)
    and ($machine.name == $expected.name)
    and ($machine.builtin == false)
    and ($machine.image.distro == $expected.image.distro)
    and ($machine.image.version == $expected.image.version)
    and ($machine.image.arch == $expected.image.arch)
    and ($machine.config.cpu_limit == $expected.cpus)
    and ($machine.config.memory_limit_mib == $expected.memory_mib)
    and ($machine.config.disk_limit_bytes == ($expected.disk_gib * 1073741824));
