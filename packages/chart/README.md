# chart

Abstract: The generic Timoni module that installs a Helm chart through Flux.
Like `namespace`, it is not bound itself: `bundle.cue` renders one instance of
it for every bound package that is not a bootstrap package, and the instance
is named after the package.

Each instance renders three objects in the namespace Flux runs in:

| Object | Content |
| --- | --- |
| `OCIRepository` | the chart, pinned by `pin.digest` from `packages/<name>/package.yaml`; a tag is refused by the package schema |
| `ConfigMap` `<name>-values` | `clusters/<cluster>/values/<name>.yaml`, with `reconcile.fluxcd.io/watch: Enabled` so a change reaches helm-controller at once |
| `HelmRelease` | installs into the namespace the binding names, reads the ConfigMap through `valuesFrom` |

All three carry `kustomize.toolkit.fluxcd.io/prune: disabled`: removing a
binding never uninstalls a chart or deletes the data in it.

A chart package needs a `package.yaml` (pin and layer) and a values file for
the cluster, even an empty one. `cilium` and `flux` are bootstrap packages
(`bootstrap: true`): the OpenTofu bootstrap reads their plain files, so they
get no instance. A package bound twice in one cluster would need two instance
names and is not supported. The environment layer of the values waits for the
first environment delta.
