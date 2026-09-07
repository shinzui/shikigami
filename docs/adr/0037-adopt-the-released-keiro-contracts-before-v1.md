# 0037. Adopt the released Keiro contracts before v1

Date: 2026-09-07

Status: accepted


## Context

The owner reconfirmed that Shikigami is unused and requested full applicable
adoption of the latest released Keiro and keiro-dsl, following the current
runtime-patterns standards. The original plan 65 covered only the release bump
and generated record edition. Its Kioku prerequisite is now published, and its
assumption that preserving every pre-release wire shape is mandatory no longer
fits ADR 0027's first-release baseline policy.

The existing domain inventory is also behind the code: Shikigami now owns the
generated RunEvidence lifecycle and transactional query rows. The queue still
uses a hand-owned bare payload even though Language 5 can supply its executable
queue contract. Conversely, the external Danwa payload and HTTP sink dispatcher
do not match the DSL's generated integration codecs and Kafka publisher model.


## Decision

Adopt every applicable released Keiro contract on the actual runtime path before
v1. Plan 65 owns the implementation and qualification. Its dependency selection
is verified against Hackage and upstream tags, including the published test
fixture package. An upstream source checkout or guidance document alone is not
release evidence.

All seven Shikigami packages use the generated compilation model: GHC2024 with
DuplicateRecordFields, NoFieldSelectors, OverloadedRecordDot and OverloadedStrings.
Records have concise fields. Generated consumers use supported record-dot or
constructor-directed access; hand-owned code keeps supported lens operations,
especially for default-option and nested updates. No selector compatibility
aliases, FieldSelectors overrides or generated-only component exemption remains.
Generated modules are still exclusively owned by the scaffolder.

Apply ADR 0027's verified pre-v1 exception to retire obsolete workflow branches,
patch IDs and compatibility-only codecs together. Adopt the generated run-job
queue envelope on both producer and consumer. Keep the checks enabled and record
intentional old-to-new breaking diagnostics before establishing the new baseline.
This supersedes pre-release retention of the approval false branch in ADR 0030
only when the exception's four facts have been rechecked. Post-release patching,
stable identities and replay rules remain governed by ADRs 0004 and 0012.

Make the evidence query targets part of an executable validated catalog while
preserving ADR 0010's atomic lifecycle/payload transaction. Rich evidence is
live-only and must be preserved and reconciled; lifecycle events cannot rebuild
it. The chosen public catalog integration must prove that guarded writes remain
atomic before it replaces the current callback. This supersedes ADR 0010's
deliberate absence of catalog/query registration, not its single lifecycle
authority or prohibition on fabricating an upstream evidence decoder.

ADR 0001's generated-code honesty rule remains absolute. Its old queue exclusion
ends when the generated codec actually becomes the runtime codec. External
protocols, HTTP publication and other genuine semantic mismatches stay
hand-owned, with current evidence and explicit owners. No unused generated facade
counts as adoption. Applicable public API gaps must be recorded and resolved;
they cannot be hidden by claiming complete adoption from compilation alone.


## Alternatives rejected

**Only bump versions and regenerate records.** This would leave applicable
queue, testing and runtime standards unexamined while the first-release window
is still open.

**Preserve every pre-release shape through dual codecs and false branches.**
That protects an empty population and creates cleanup work. It becomes necessary
only if the verified pre-v1 conditions no longer hold.

**Declare every available DSL node.** A Kafka publisher declaration cannot
certify an HTTP sink dispatcher. The declaration must describe executed behavior.

**Call evidence replayable so the catalog looks complete.** Encode-only rich
payloads are absent from lifecycle history. A destructive replay would lose data.


## Consequences

Plan 65 includes source and workflow changes, generated queue adoption, catalog
integration, test fixture adoption and runtime qualification. Edition migration
first proves byte preservation; intentional baseline resets have separate
fixtures and diagnostic evidence. Implementation remains pending at acceptance
of this decision.

The pre-v1 exception expires at first release or deployment. It authorizes no
deletion of a database and provides no compatibility promise across a later
deployment. Shared/external contracts and authorization constraints remain intact.


## References

* [Plan 65](../plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md)
* [ADR 0001](0001-declare-only-what-the-runtime-executes.md)
* [ADR 0002](0002-generated-code-is-not-formatted.md)
* [ADR 0004](0004-one-options-value-and-a-checked-patch-set.md)
* [ADR 0010](0010-run-evidence-lifecycle-and-payloads-have-one-atomic-boundary.md)
* [ADR 0012](0012-a-declared-workflow-body-only-grows-behind-a-patch.md)
* [ADR 0027](0027-the-first-release-establishes-one-clean-durable-baseline.md)
* [ADR 0030](0030-an-approval-request-is-a-durable-child-workflow.md)
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-generated-haskell-editions`
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-dsl-adoption`
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-projection-catalogs`
* `mori://shinzui/keiro-runtime-patterns/docs/keiro-runtime-assembly`
* `mori://shinzui/keiro-runtime-patterns/docs/architecture-test-layout`
* `mori://shinzui/haskell-jitsurei/docs/core-record-patterns`
