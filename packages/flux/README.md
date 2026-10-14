# flux

Abstract: Flux itself, as a Flux package. The Flux Operator chart and the
`FluxInstance` it reconciles are applied by the OpenTofu bootstrap once, before
Flux exists; Flux then adopts both and upgrades them from these manifests. The
package is a bootstrap package (`bootstrap: true` in `package.yaml`), so the
chart module renders no instance of it.

| File | Content |
| --- | --- |
| `package.yaml` | the Flux Operator chart pin and the pod ports the kubelet probes (8081, 9090, 9440) |
| `ocirepository.yaml`, `helmrelease.yaml` | the operator release, adopted under the same name in `flux-system` |
| `fluxinstance.yaml` | the Flux distribution and components, and the sync that points Flux at this repository's branch; `${git_branch}`, `${cluster}` and `${environment}` come from the `flux-runtime-info` ConfigMap |
| `tests/cluster/` | the read-only cluster suite that checks Flux owns its own releases |

Removing Flux or the operator takes an explicit teardown: both objects carry
`kustomize.toolkit.fluxcd.io/prune: disabled`.
