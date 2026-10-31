# 0092. Review values are checked and source citations use structured coordinates

Date: 2026-10-31

Status: accepted

## Context

PracticeKey, OwnerPrincipal, EvidenceId, ClaimId and ContentHash are distinct
review concepts, but their public constructors and Generic instances admitted
blank values. Confidence similarly admitted values outside its documented
0..100 percentage. Whole-document validation already rejected those values.

A separate public-validator regression admitted two opaque content responses
with path/hash pairs `docs/adr/claim:a`/`h` and `docs/adr/claim`/`a:h`. Their
colon-joined source citation ids were equal. Two existing coordinate controls
passed. This exercises the abstract EvidenceReader contract, whose content hash
is opaque and nonblank; it is not live Mori content-plane qualification. The
production capability still explicitly reports an unavailable content reader
until an adapter is installed.

## Decision

The six review values have private constructors and no Generic, numeric, string
literal or enumeration construction. Text factories reject blank values while
preserving exact nonblank strings. Confidence admits only integer percentages
0..100. JSON uses the existing strings and numbers. Whole-document normalization,
citation-graph checks, owner rules and resolution authorization remain their
existing authorities. Remove redundant whole-document checks for these refined
scalar invariants.

Raw PinnedContent, PinnedDiff and PinnedTreeEntry are explicit content-plane reply
records. Their hash field is Text, like their raw revision/path metadata. Blob and
diff admission refine it once to ContentHash and retain the existing
MissingContentHash refusal. Validated citations and diff views keep ContentHash.
Do not invent a SHA-only format for this abstract reader's opaque hash contract.
A checked hash value does not authenticate content or replace the reader's
provenance, path, size, redaction and limit checks.

Source citation labels use `evidence-v2:` plus a UUIDv5 commitment in the existing
practice-review coordinate namespace. The name is an unambiguous length-prefixed
sequence: source-evidence purpose, version 2, role, repository, pinned revision,
path and opaque hash. Role participates and identical coordinates repeat. Keep
frozen vectors. A diagnostic claim has a separate total factory preserving the
existing evidence-problem ordinal label. The zero-confidence factory preserves
the incomplete-verdict value.

Practice keys and owner principals are registry/external-authority locators.
EvidenceId and ClaimId are citation labels checked within one verdict graph,
including model-provided labels. They are not allocated review/resolution entity
ids. ReviewId/ResolutionId allocation authority remains a separate open audit;
this decision does not exempt them from the TypeID default.

## Alternatives rejected

Leaving scalar checks solely in the whole validator permits invalid direct
construction. Generic conversion would bypass the private readers. Another
separator cannot disambiguate opaque path/hash components. Rejecting colons or
requiring an invented hash algorithm would narrow a valid reader contract.
Treating raw replies as validated values would erase the real admission boundary.

## Consequences

Complete existing trigger, five-classification verdict and four-outcome resolution
fixture bytes remain unchanged. Their nonblank scalar values and numeric
percentages retain their codecs. Invalid scalar JSON now refuses at decoding.
Getters at memory scope/tag, recipient, authorization and commitment adapters
preserve existing lowering. The Flow's labels, order, effects and zero/diagnostic
values remain unchanged under the workflow-versioning review standard.

Fresh acquired source-citation identities intentionally change under ADR-27's
confirmed unused first-release baseline. There is no old factory fallback or
populated cross-build promise. A neutral native helper-reference/fold report
cannot certify old producer identity meaning. Retain the failed control and
qualify complete codecs, private construction, graph behavior, same-build memory
and authorization/recovery before accepting the candidate.

## References

[ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md),
[ADR-31](0031-practice-review-adjudication-is-a-logical-memory-transition.md),
[ADR-80](0080-opaque-checked-values-do-not-expose-generic-construction.md),
[ADR-81](0081-validated-results-use-private-seals-and-public-read-views.md),
[workflow versioning](../workflow-versioning.md),
[the failed admitted-coordinate control](../evidence/keiro-0.22/practice-values-before-regressions.txt),
[the v2 vectors](../evidence/keiro-0.22/practice-values-vectors.json),
[the acceptance record](../evidence/keiro-0.22/practice-values-results.txt),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
and [the scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
