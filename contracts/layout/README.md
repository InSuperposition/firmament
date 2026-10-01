# layout

Abstract: The repository layout as data (`layout.yaml`), checked against
its closed schema (`schema.cue`) by `mise run contracts:lint`. It lists
each top-level folder, what it may reference and what it must never do,
the places a cluster name appears (renaming one is a migration, C40), and
which rules a tool checks and which only review checks (C79).

Most of these rules are about code, and no tool reads code for them, so
they are review checks. The one standalone check is that chainsaw suites
only read the cluster (`chainsaw:lint`). Rules about data are checked by
the tool that reads the data (C57).

A change to the layout changes `layout.yaml` and the README Structure
together.
