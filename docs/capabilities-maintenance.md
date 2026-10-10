# Maintaining the capability catalog

[The catalog](capabilities/index.md) records what a consumer can adopt from the
current Shikigami implementation. It uses the shared
[capabilities profile](mori://shinzui/okf-profiles/profiles/capabilities), pinned to
the upstream `v0.20.0` tag with a Dhall integrity hash. Loading this profile needs
`okf` 0.9.0.0 or later. The bundle declares OKF 0.2 and is registered in
`mori.dhall` as `capabilities`.

The [coverage census](capabilities-coverage.md) maps the seven packages, exposed
module families, binaries, and administrative commands to records and states
which supporting or unavailable surfaces are excluded. Refresh it when adding
public surfaces; catalog validation alone does not prove completeness.

Each flat Markdown concept describes one independently adoptable provision,
identified by a stable `CAP-N` handle. Preserve the handle when renaming or
revising a record. Allocate new handles with:

```sh
okf id next docs/capabilities CAP --profile docs/capabilities/profile.dhall
```

Use the canonical address when referring to a record from another repository:

```text
mori://shinzui/shikigami/okf/capabilities/concepts/CAP-1
```

## Authoring claims

Support every claim with repository evidence a reader can open: tests, source,
examples, conformance fixtures, benchmarks, or guides. Explain what each artifact
proves and link it in the body as well as `evidence`. Read its contents before
expanding a claim. A file's existence does not establish that the claim is true,
and linking a test does not mean that test was run for this documentation change.

Use `status: shipped` for implemented provisions and `stability: experimental`
until a compatibility promise is established. These are separate questions:
implemented code can still be unreleased and experimental. Use `since: unreleased`
while the implementation has no release; use a bare first release version once
history establishes it. If history cannot establish a version, use `unknown`
and explain why in the body. The initial catalog checked local and upstream tags
and published releases; none existed for Shikigami.

Describe deployment prerequisites and partial implementations in `Limits`.
Schema alternatives, stubs, and planned endpoints are not evidence of a working
feature. Missing capabilities belong in improvement requests. A multi-service
business outcome belongs in a consuming project's use case; a Shikigami record
can describe its enforcing client or runtime integration while stating the
external dependency.

For every `requires` handle, add a body link to the corresponding concept.
Frontmatter alone does not create an OKF graph edge. Deprecation or withdrawal
requires `replacedBy` with a concrete migration destination.

## Regeneration and validation

After editing records, add a dated entry to `capabilities/log.md`, then run:

```sh
just capabilities-index
just capabilities-validate
mori validate
okf graph docs/capabilities
```

`capabilities-index` regenerates the reserved index. Keep explanatory prose here
so regeneration cannot erase it. `capabilities-validate` enforces the profile and
log, then checks repository evidence paths, local Markdown file links, and graph
edges for local requirements. The supplemental checker uses OKF's JSON parser
output and Python's standard library; it adds no YAML dependency. Remote evidence
is outside its existence check, and it cannot verify semantic claims.

Independent review has not occurred for the initial machine-authored records.
They have truthful `generated` provenance and no invented `reviews` or `verified`
entries. The standard validation command therefore omits `--strict`. To see
recommended-field advisories, run:

```sh
okf validate docs/capabilities --strict \
  --profile docs/capabilities/profile.dhall
okf trust docs/capabilities
```

Record real reviews when they happen and mirror approving reviews into `verified`
as the shared profile requires for accurate derived trust. Profile changes should
use an authoritative upstream tag and a freshly computed Dhall hash. The initial
descriptor was generated with `okf profile init --registry` against the released
catalog rather than the older registry configured in the local CLI.

After changing `mori.dhall` or adding records, refresh local discovery with
`mori register --local` and verify a handle with `mori path`.
