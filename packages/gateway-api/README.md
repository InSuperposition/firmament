# gateway-api

## Abstract
The Gateway API custom resource definitions that Cilium's Gateway controller requires, vendored so that Flux applies them from Git and the version is reviewable. Cilium 1.20 documents Gateway API v1.6.1 ([Cilium Gateway API](https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/gateway-api/)).

## Goals
- Hold exactly the upstream `standard-install.yaml` of the release Cilium tested.
- Keep every definition when a Git change removes it (`prune: disabled`).

## Constraints
- `crds.yaml` is the upstream file, unedited. Local changes go in `kustomization.yaml`.
- Version: v1.6.1, standard channel, https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml
- SHA-256 of `crds.yaml`: `24d931f22abd8e40c973264319ead7cfa09d0fb7716b7ab1ee2ff174cb063a73`
- It holds the seven definitions Cilium requires (GatewayClass, Gateway, HTTPRoute, GRPCRoute, BackendTLSPolicy, ReferenceGrant, TLSRoute), the optional ListenerSet, TCPRoute and UDPRoute, and the upstream `safe-upgrades` ValidatingAdmissionPolicy with its binding.
- `mise run gateway:check-crds` compares `crds.yaml` and the release at the URL above with that checksum. Change the version, the URL and the checksum together, and run it.
- Upgrade one Cilium minor at a time and read its upgrade notes on the Gateway API version before changing the file.
