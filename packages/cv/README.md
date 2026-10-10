# cv

Abstract: The cv site, installed by the [chart](../chart/README.md) module
from the chart the cv repository publishes to ghcr.io. The pin and the
signer Flux checks are in `package.yaml`; the image, pinned by digest, is in
`clusters/<cluster>/values/cv.yaml`. A new release means a new chart digest
in `package.yaml` and a new image digest in the values.

The chart's own `values.schema.json` refuses an image that is not a digest.
The namespace of the binding is denied by default; this package allows the
node's probes on port 44100 and nothing else.
