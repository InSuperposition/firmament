# kyverno

Abstract: the Kyverno admission engine, installed by the
[chart](../chart/README.md) module into the `kyverno` namespace of the
platform tenant. The pin is in `package.yaml`; the cluster's values are in
`clusters/<cluster>/values/kyverno.yaml`. The chart installs its CRDs with the
release. The policies live in the `kyverno-policy` render module and apply only
after this release is Ready.

The upstream chart carries no cosign signature (the registry holds none for
the pinned digest), so the digest pin is the only check and the package has no
`verify` block.
