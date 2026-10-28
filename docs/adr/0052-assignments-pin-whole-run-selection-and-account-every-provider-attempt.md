# 0052. Assignments pin whole-run selection and account every provider attempt

Date: 2026-10-27

Status: accepted

## Context

Assignments need different model settings in one process. Mutable defaults cannot
identify pending work after a deploy. Decision slots already have an operator
catalog and retained bindings. Baikai options and evidence are encode-only and
cannot serve as application replay codecs.

## Decision

Whole-run `execution` permissions are separate from `decisionModels`. Admission
intersects declaration, explicit user requirements, inherited permissions, profile
and operator catalog. Explicit conflicts refuse. An unused whole-run default does
not participate in a decision-only Flow. Historical declarations retain defaults.

A new assignment journals `ExecutionSelection`: immutable public descriptor,
effective credential-free options as application JSON, narrowed aliases, profile
reference, resource root and admission time. Runs use stable workflow identities;
conversation messages have distinct stable assignment identities. Conversation
roots and user constraints survive rotation and cannot change within a live epoch.
Conversation overlays remain unavailable.

Resume finds the exact descriptor and opaque binding identity/version among active
or retained bindings. It never resolves the mutable alias again. A missing binding
produces `PinnedBindingUnavailable`. New assignments also pin the process default;
a changed default refuses rather than replacing pending work. Credentials remain
process-local and may rotate without changing binding authority.

A private provider registry handles complete and streamed calls without changing
the process default. The shared HTTP builder and profile tuple predicate remain
authoritative. Dispatch validates the model/options, credential binding, current
identity authority and root admission, then rechecks authority immediately before
IO. Profile authority checks resolve only the pinned id/version and require the
same digest; revocation or expiry refuses without changing the recorded policy.
Evidence keeps the strongest binding, caller and profile requirement.

Root reservation, assignment admission and call receipt commit in one transaction,
locking the root first. An identical receipt permits observation, not redispatch.
Fresh attempts consume durable call/retry/concurrency and token limits. Profile
deadlines start at recorded admission and constrain the real transport timeout.
Requested descriptors and reported model ids stay separate. Call facts store
request digests, never prompts or tool arguments. Normalized compliance uses the
same `Attestation.CallFacts` codec as decision evidence, without another lifecycle.

A known terminal transport releases active capacity despite missing billing.
Known dimensions settle once; missing dimensions stay held and unknown until
reconciliation. Uncertain transports retain active capacity too. Estimated catalog
cost is not provider-reported billing. HTTP cannot enforce a hard invoice ceiling,
so finite cost ceilings refuse dispatch. Finite token ceilings reserve a
conservative context/output bound with explicit supported output limits;
infeasible envelopes refuse admission.

Queue codec v3 carries typed selection metadata. Retained v1/v2 upcasters supply
absent selection authority unconditionally, even if historical JSON resembles new
metadata. Both workflow additions retain real old branches under declared patches.
Roll out readers before writers; roll forward after writing new journals.

## Alternatives rejected

Global model switches race assignments. Alias lookup on resume changes admitted
work. Decision permission reuse grants different authority. Process-local retry
counters reset on crashes. Missing invoices interpreted as zero refund uncertainty.

## Consequences

Keep bindings needed by pending assignments or accept an explicit refusal.
`runs show --json` exposes descriptors, binding availability and at most 100 call
facts, excluding effective options and payloads. Accounting survives workflow GC.
The separate transcript still owns accepted model/tool outcome recovery.

## References

- [Plan 82](../plans/82-pin-governed-execution-settings-for-agent-assignments.md)
- [ADR 0007](0007-a-resolved-profile-is-a-run-local-policy-snapshot.md)
- [ADR 0051](0051-resource-roots-own-conservative-reservations-and-actual-attempts.md)
- [Workflow versioning](../workflow-versioning.md)
- `mori://shinzui/baikai` — provider registries and encode-only options/evidence; artifact-level source URI coverage is pending.
