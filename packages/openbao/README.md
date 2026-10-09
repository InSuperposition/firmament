# openbao

Abstract: OpenBao, the cluster's root CA, installed by the
[chart](../chart/README.md) module. The pin is in `package.yaml`. The server
config is not written by hand: `config/` is a CUE package that validates
`clusters/<cluster>/openbao.yaml` and builds the config string and the chart
values that must agree with it. `inputs.cue` merges them into
`clusters/<cluster>/values/openbao.yaml`, and a values file that sets one of
those keys is refused.

What the config does, in the order OpenBao runs it on its first start:

| Step | What |
| --- | --- |
| listeners | a plain one on the pod's loopback, which the ACME client and the chart's probes use, and a TLS one on 8443 whose certificate OpenBao gets from its own PKI over ACME |
| seal | static, from the Secret `openbao-static-seal` that `mise run openbao:seed` creates from private state |
| audit | to the container log |
| `initialize` blocks | the PKI mount, root, ACME and roles; the ACL policies; Kubernetes auth for cert-manager; certificate auth for the operator, trusting the CA in the ConfigMap `openbao-operator-ca` |

A failed first start is sticky: OpenBao refuses to unseal until its storage is
wiped. The schema in `config/config.cue` therefore requires every decision a
wrong value would make permanent, and the golden file
`config/testdata/openbao.hcl` fixes the exact text the server reads.

`provides.port` in `package.yaml` is 8443, the pod's TLS port, not the
Service port 8200 that maps to it: the network policy matches the port the pod
listens on.
