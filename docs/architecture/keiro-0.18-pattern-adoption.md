# Keiro 0.18 pattern adoption

Shikigami adopts the released Keiro 0.18.0.0 package family and the guidance at
`mori://shinzui/keiro-runtime-patterns` revision
`24e4e61075ccc323cc1b443775963805b7059bee`. The relevant standards are
`mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption`,
`mori://shinzui/keiro-runtime-patterns/docs/keiro-mapped-consumer-surfaces`,
`mori://shinzui/keiro-runtime-patterns/docs/keiro-identifier-domains`,
`mori://shinzui/keiro-runtime-patterns/docs/keiro-behavior-conformance`, and
`mori://shinzui/keiro-runtime-patterns/docs/migrations-testing`.

## Checked value mappings

Keiro 0.18 adds checked mappings for a bare `Optional`, `List`, or `Map`, for calendar `Day`, for
`Set Text`, and for bytes encoded with the `base16-bytes` policy. None applies to a current
Shikigami declaration. The generated ledger has no mapped consumer declaration using those
shapes. Its only mapped coverage root is the existing generated `RunEvidenceId` nominal in a
snapshot register; it is not an opaque codec that one of the new value policies can replace.
The run-job queue keeps two explicit `Json` fields because `identity` and `triggerPayload` cross
the established application adapter in `Shikigami.RunJobs`. Changing either field's wire policy
would be a separate persisted-contract change with its own compatibility and drain evidence.

## Identifier admission

`RunEvidenceId` remains `domain=typeid-v7`, lowered through `typeIdV7Domain`. The service does
not adopt the new v5-or-v7 admission because this generated TypeID is allocated as v7 and no
retained v5 value belongs to that domain. UUIDv5 values used for workflow identity and
deduplication are technical identifiers outside the declared `RunEvidenceId` contract. Widening
admission would change fold and replay identity, so it requires a separate plan and rollout.

## Remaining application obligations

The three hand-owned obligations remain justified by capability:

- `Shikigami.ProjectionCatalog.ProjectionCatalogHoles` supplies the live-only rich-evidence
  projection handler because lifecycle events cannot reconstruct the payload.
- `Shikigami.RunEvidenceLookup.ReadModelHoles` supplies the read-model SQL implementation.
- `Shikigami.RunEvidence.BehaviorHoles` supplies executed witnesses for every generated aggregate
  behavior obligation.

The 0.18 scaffold preserves these create-once files and changes only generated provenance
banners. `Shikigami.RunEvidence.Conformance` continues to require every obligation to be filled
and passing, and additionally requires every total generated guard to appear in the verified
set. Six command/register identity-equality guards retain passing witnesses but remain honestly
unverified because their generated guard coverage is not proof-strength. The gate does not
relabel them to claim stronger evidence.

## Qualification

`just keiro-check` reports no diagnostics, no opaque persisted roots, and no new binding
obligations. `just keiro-inspect` reports all five workspace members explicitly declared at
candidate Language 6. The compatibility report against
`eb8395ac2646f742dad2e8dc6ced9640a6b4dd1e` contains no findings or coordination impact, and its
replay-impact verdict is `replay-neutral`. Regeneration changes one version-banner line in each
of 28 generated artifacts and changes no `domain/*.keiro` source or semantic ledger row.
