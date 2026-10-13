<!-- Open with ?template=new-binding.md on the compare URL. -->

## Request: bind a package to a namespace

- Package: `packages/<name>/` (new or existing)
- Namespace:
- Tenant (must exist in `environments/<env>/tenants/`):
- Environments that need it:
- Ports other pods or the Gateway reach (`host_ports`, `cluster_ports`, `ingress_ports`):
- Capabilities it requires or provides:
- Chart source and digest pin; signed by (issuer and identity), or why unsigned:

## Changes

- [ ] a binding in `clusters/<cluster>/packages.yaml`
- [ ] `packages/<name>/package.yaml` and `clusters/<cluster>/values/<name>.yaml`
- [ ] the tenant's quota still covers the namespace

## Checks

- [ ] `mise run check` passes
- [ ] `mise run inventory:generate` shows the new namespace and package
