# cilium-policy

Abstract: the Timoni module that renders the network policy of an environment
for Cilium. It is a render module, not a Flux package: `render/bundle.cue`
renders one instance, and Flux applies its objects through the `rendered`
Kustomization. `inputs.cue` resolves what each namespace provides, requires and
exposes from the bound packages' `package.yaml` files; the module turns that
into policy objects.

| Object | Rendered for |
| --- | --- |
| `CiliumNetworkPolicy` `platform` | each namespace that has a policy, in one of four modes: `full` (default-deny both ways and every allow), `ingress` (ingress default-deny; egress open), `host` (only the allow for the node and the API server), `allow` (only the allows; the tenant-wide deny supplies the rest) |
| `CiliumClusterwideNetworkPolicy` `tenant-default-deny` | every namespace the platform tenant does not own, in both directions, with DNS the only way out |
| `ConfigMap` `cilium-values-policy` | the Cilium values that switch allow-localhost to `policy`, read by the Cilium release as an optional second values source |

The module is placement-free: it names no cluster, environment or namespace of
its own; `inputs.cue` supplies them. The clusterwide deny and the values
ConfigMap carry `kustomize.toolkit.fluxcd.io/prune: disabled`, so removing a
binding never lifts the deny. The recorded renders of the platform namespaces'
policies are in `tests/render/golden/platform-policy/`.
