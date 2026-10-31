# 0089. Protected payload references retain checked units

Date: 2026-10-31

Status: accepted

## Context

Execution and worker-session payload owners already recompute body hashes and
encoded sizes, compare their stored metadata and enforce scope and access. Their
reference fields nevertheless accepted arbitrary Text and Integer values. Git
and process routing repeated syntax checks after these primitives crossed
application boundaries. Database decoder failure must not disguise malformed
owned evidence as transport unavailability.

## Decision

Use three private, non-Generic units throughout PayloadRef and its consumers:
PayloadId is an exact 1..256-character locator without C0 controls;
PayloadDigest is `sha256:` followed by 64 lowercase hexadecimal digits;
PayloadByteCount is a positive signed-int64 count of encoded JSON bytes. Checked
JSON readers preserve valid string and numeric wire values. No unchecked
constructors, representation coercions, numeric literals or Generic construction
are available outside their owner.

Execution bindings and retained Git/process routing keep PayloadDigest. Native
commands, SQL encoders and external capability adapters render explicitly.
Persistent owners still enforce their separate 1 MiB body limit before writing.
Ephemeral summary references retain their own policy and do not acquire a global
1 MiB input limit. A byte count is distinct from a resource accounting amount.

PayloadRef remains an ordinary reference record. Valid scalar syntax proves
neither existence nor body authenticity. Owner reads still verify the body,
digest, bytes, payload kind, session/execution scope and authorization together.
SQL rows capture metadata refinement as an Either value: malformed metadata
refuses as CorruptReplay or SessionBindingConflict, preserving the distinction
from database transport errors. Whole-transaction refusal remains mandatory.

Persistent locators are content-addressed under the existing owner namespaces;
the ephemeral locator is a local summary sentinel. These are lookup coordinates,
not newly allocated application entities. TypeID-v7 allocation would destroy
their existing content identity. Other workspace hashes retain their own meaning;
a file-input hash is not silently relabeled as an execution payload hash.

## Alternatives rejected

A universal positive integer wrapper would mix payload bytes with accounting
units. Treating a checked reference as authenticated evidence would bypass its
owner. Hasql decoder refinement that throws for malformed metadata would change
a corruption refusal into database unavailability. A universal persistence size
limit would tighten ephemeral input policy incidentally.

## Consequences

Valid body hashes, locator bytes, JSON field names and numbers, native command
payloads and action commitments remain unchanged. Invalid scalar references now
refuse at decoding/construction under the unused first-release baseline. SQL
corruption regressions cover invalid digests and zero byte counts; existing
scope, body, authorization and replay tests remain required. No old-binary or
populated cross-build replay promise is introduced. This decision completes one
part of the scalar census; it does not close the whole audit or Linux release
qualification.

## References

[ADR-27](0027-the-first-release-establishes-one-clean-durable-baseline.md),
[ADR-53](0053-execution-lifecycle-and-protected-replay-share-an-atomic-boundary.md),
[ADR-80](0080-opaque-checked-values-do-not-expose-generic-construction.md),
[ExecPlan 107](../plans/107-adopt-current-haskell-and-service-architecture-practices.md),
[the acceptance record](../evidence/keiro-0.22/payload-values-results.txt),
and [the scalar standard](mori://shinzui/keiro-runtime-patterns/docs/architecture-domain-newtypes-and-typeids).
