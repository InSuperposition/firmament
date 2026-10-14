# namespace

Abstract: the Timoni module that renders the namespaces of an environment and
what every tenant namespace carries. It is not a Flux
package: `timoni/bundles/bundle.cue` renders one instance, and Flux applies it through
the `rendered` Kustomization. `inputs.cue` resolves the bindings into
`namespaces` (namespace to tenant) and `installers` (namespace to installer
account name).

| Object | Rendered for |
| --- | --- |
| `Namespace` | each bound namespace, labelled `firmament.dev/tenant` and `firmament.dev/environment`; non-platform tenants also get `pod-security.kubernetes.io/enforce: baseline`; pruning is off, so removing a binding never deletes a namespace |
| `ResourceQuota` | each namespace, from the tenant's `namespace_quota` |
| `LimitRange` `tenant-defaults` | each namespace; default container requests, so a quota on requests does not refuse a pod that sets none |
| `ServiceAccount` `installer-<namespace>` and `RoleBinding` | each non-platform tenant namespace: the account lives in `flux-system`, where the tenant's HelmRelease resolves `serviceAccountName`, and the binding gives it the built-in `admin` role in that namespace only |

A namespace that names a tenant the environment does not define is refused when
the module renders. A retired binding keeps all of these objects; only its chart
objects stop rendering.
