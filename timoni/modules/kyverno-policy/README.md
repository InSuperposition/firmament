# kyverno-policy

Abstract: the Timoni module that renders the admission policies of an
environment for Kyverno. It is not a Flux package:
`timoni/bundles/admission-bundle.cue` renders one instance into
`clusters/<cluster>/admission/<environment>`, and the `kyverno-policy` Flux
Kustomization applies that folder after the `rendered` Kustomization, which is
Ready only when the Kyverno release is. A policy therefore never reconciles
before its definition exists.

| Object | Content |
| --- | --- |
| `ImageValidatingPolicy` `require-signed-images` | denies a pod in a tenant namespace unless every image carries a keyless cosign signature from the signer in `inputs.cue` (the cv workflow); a `ClusterPolicy` cannot find a cosign v3 bundle stored as an OCI referrer, so this kind is used; webhook timeout 30 s |
| `ValidatingPolicy` `deny-ephemeral-containers` | denies any ephemeral container in the same namespaces (an image policy cannot cover `pods/ephemeralcontainers` on Kyverno 1.19.1); admission only |

A tenant namespace is one with the `firmament.dev/tenant` label whose value is
not a platform tenant; the platform tenant names are generated from the tenant
files. `mise run kyverno:verify` checks both refusals on a live cluster.
