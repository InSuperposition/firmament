# layout

Abstract: The repository layout as data (`layout.yaml`). It lists each
tracked top-level folder, what it may reference and what it must never do, the
three kinds of directory under `packages/`, where to look for common tasks
(`find`), the places a cluster name appears (renaming one is a migration, C40),
and which rules a tool checks and which only review checks (C79).

Three tools read it:

- `mise run contracts:lint` checks the file against its closed schema
  (`schema.cue`).
- `mise run layout:lint` checks it against the tracked tree: the folders must
  equal the tracked top-level folders, every `may_reference` entry must name a
  folder, every `find` path must be tracked, every directory under `packages/`
  must have a kind (detected from the tree, never listed here) and a tracked
  README, and the README Structure block must be the render of this file. It
  reads only and never writes.
- `mise run layout:format` writes that README block between its markers from
  this file and the tracked tree, and changes nothing else. It refuses, and
  writes nothing, when the markers are absent, duplicated or out of order.

Most of the rules about code are review checks: no tool reads code for them.
The standalone checks are that chainsaw suites only read the cluster
(`chainsaw:lint`) and the ones `layout:lint` makes. Rules about data are
checked by the tool that reads the data (C57), which is why the tree checks are
not part of `contracts:lint`.

A change to the layout changes `layout.yaml`, and `mise run layout:format`
regenerates the README block.
