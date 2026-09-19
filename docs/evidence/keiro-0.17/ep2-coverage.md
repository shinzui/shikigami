# EP-2 Language 6 and generated-contract evidence

All five workspace members declare `language keiro-dsl 6`. Keiro 0.17 is a
released package family; its registry separately labels Language 6 as
`Candidate CandidateLanguage`, with syntax profile 5 and runtime semantics 5.
`just keiro-check` and `just keiro-inspect` pass with a Language 6 floor, declared
source forms, no opaque persisted roots, and the expected candidate support label.
Scaffolding regenerated the checked layer with Keiro 0.17 banners and remains
deterministic.

The language move changes source-language provenance and generated formatting,
not workflow names, queue names, fold semantics, JSON envelopes, or runtime step
shapes. The change in `Shikigami.Agent.Run.recallPriorLearnings` is action-internal:
it adopts Kioku 0.7's explicit host-owned AI runtime and retains keyword fallback.
It does not add, remove, rename, or reorder a durable workflow step, so
`docs/workflow-versioning.md` requires no patch branch.

Nominal admission was evaluated field by field in
`docs/architecture/shikigami-domain-inventory.md`. Current run-job scalars are
refined values, opaque upstream IDs, composite identities, or enums with frozen
Aeson spellings; none is a total nominal isomorphism eligible for a Language 6
consumer binding. `WireCompatSpec` already executes the production generated
decoder and rejects invalid agent names, run keys, delegation depths, lineage,
session/workflow IDs, and enum strings while pinning the valid envelope bytes.

Evidence commands:

```text
nix develop --command just keiro-check
nix develop --command just keiro-inspect
nix develop --command cabal build all
```
