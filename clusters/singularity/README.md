# singularity

Abstract: The one cluster definition (C92): what Flux applies to the
cluster and the read-only suite that checks it. Every environment whose
`environment.yaml` names `singularity` deploys this same folder, so it
never holds an environment name or an environment fact (address, CIDR,
size); those come from the runtime values the Kubernetes root computes.

| Path | Holds |
| --- | --- |
| `flux/kustomization.yaml` | the packages Flux applies, by path into `packages/`; the FluxInstance syncs `clusters/${cluster}/flux` |
| `tests/cluster/chainsaw-test.yaml` | the cluster's own read-only suite (nodes Ready, no kube-proxy, no k0s Charts); `env:verify` runs it, then each listed package's suite |

Renaming the cluster is a documented migration (C40): the folder, the
`cluster` field of each `environment.yaml` that names it, and the places
the layout contract lists.
