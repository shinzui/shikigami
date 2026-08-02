---
type: Improvement Request
title: Attest sanctioned model execution for agent runs
description: Resolve a versioned execution profile before a run, collect every correlated model call, bind the result to the exact reviewed artifact and agent version, and issue a signed tamper-evident run attestation.
timestamp: "2026-08-02T18:29:04Z"
requestId: IR-7
status: proposed
origin: mori://shinzui/kikan
---

# Improvement Request: attest sanctioned model execution for agent runs

## Why

Shikigami currently records a completed Kioku session's `modelUsed` from the configured
`BehaviorEnv`. That distinguishes a stub from a configured real model, but it is not enough for a
critical code-review gate: it does not record thinking level, provider-observed metadata, all calls in
a multi-call program, retries, delegated child runs, the sanctioned policy version, or the exact code
change and review result.

Use case `mori://shinzui/kikan/okf/use-cases/concepts/UC-8` requires a verifier to answer a narrower,
auditable question: did the trusted agent runtime execute this review of this immutable code change
using only model calls permitted by this exact sanctioned profile? Baikai supplies the call-level
observations requested by `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-3`; Shikigami
owns their run-level meaning and lifecycle.

## Sanctioned execution profiles

Introduce an immutable, versioned execution profile referenced by an agent deployment or run request.
At minimum it contains:

- profile id, version, canonical digest, issuer, validity window, and lifecycle;
- allowed provider, API/transport, endpoint class, pinned model ids, and canonical thinking levels;
- whether aliases, defaulted thinking, provider fallback, model fallback, effort clamping, and CLI
  transports are allowed;
- minimum evidence strength and required provider correlation fields;
- limits for calls, retries, delegated child runs, tokens, cost, duration, and concurrency;
- signer and retention requirements for the final attestation.

Policy applies to allowed tuples such as `(provider, API, model, thinking)`, not to independent model
and thinking allow-lists. The runtime resolves and journals the profile before behavior execution.
Unknown, expired, withdrawn, ambiguous, or mutable profiles fail closed. An in-flight run remains
pinned to the resolved digest.

The profile is runtime policy, not prompt content. A model, skill, repository checkout, tool result, or
child agent cannot broaden it.

## Run evidence lifecycle

Create a durable run-evidence aggregate or equivalent journal with these phases:

```text
requested -> profile-resolved -> running -> evidence-sealed -> attested
                                      \-> non-conforming
                                      \-> incomplete
                                      \-> failed
```

Before execution, bind the run to:

- logical agent and immutable agent/deployment version;
- declaration, behavior/skill or serialized Shikumi program, grounding, and tool-catalog digests;
- canonical repository identity, full base/head commit SHAs, and reviewed diff or tree digest;
- the sanctioned profile digest;
- the approval/review request id and idempotency key.

Every Baikai call receives the Shikigami run id and a unique call id. The aggregate collects terminal
`ModelCallEvidence` records, preserving retry and parent/child relationships. It seals only after the
behavior and every relevant child run are terminal.

## Compliance verdict

A run is `sanctioned` only when:

- every model call conforms to the pinned profile;
- no relevant call, retry, continuation, or delegated child is missing evidence;
- no prohibited default, alias, fallback, transport, endpoint, or effort translation was used;
- the reviewed artifact still matches the bound repository and diff digests;
- the stored review result matches the result digest in the evidence set.

The roll-up records every non-conforming reason rather than reducing partial evidence to a Boolean.
Deterministic steps are `not-applicable`, not fabricated model calls. A run using several permitted
models remains a mixed-model run and lists each call.

## Signed attestation

After sealing, canonically encode and hash the portfolio `AgentRunAttestation` contract from
`mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`. Sign the hash with a workload-controlled
key that is unavailable to the agent behavior and repository workspace. Record the algorithm, key id,
signing identity, certificate or verification reference, issuance time, and schema version.

Prefer a separate trusted attestation/egress component when deployment architecture permits it; a
signature produced by the same unrestricted process that may fabricate evidence offers weaker
assurance. Key rotation must not make historical proofs unverifiable.

Publish a bounded read API and offline verifier input for retrieving the attestation by run id or
review request id. Kioku may retain `modelUsed` and an attestation reference as a convenient session
summary, but it is not the canonical audit store.

## Trust statement

The first release proves that a trusted sanctioned runtime emitted specific provider requests,
received correlated responses, and bound those observations to a code review. It does not claim
independent proof of provider-internal computation. The evidence explicitly distinguishes:

1. declared configuration;
2. runtime-observed request/response evidence;
3. Shikigami-signed run attestation;
4. provider-attested or confidential-computing evidence, when a future provider supplies it.

## Acceptance

This request is complete when:

1. A declared review agent cannot start without resolving an active execution profile to an immutable
   digest.
2. Tests reject unset/default thinking, mutable aliases, forbidden transports, model or effort
   fallback, expired profiles, and incomplete required provider metadata.
3. A two-call Shikumi fixture, a retry fixture, and a delegated-child fixture produce one roll-up that
   accounts for every call exactly once.
4. The attestation binds canonical repository identity, full revisions, diff digest, agent and
   behavior artifacts, profile digest, and review-result digest.
5. A changed commit, diff, result, profile, call record, or signature makes verification fail.
6. Signing credentials are not visible to the behavior, prompt, tools, or workspace, and key rotation
   preserves historical verification.
7. A read API and offline fixture let Kotei verify the proof without access to Shikigami's database.
8. The end-to-end UC-8 conformance fixture yields `sanctioned` for the permitted run and explicit
   non-conforming verdicts for model, thinking, fallback, missing-call, artifact, and signature
   mutations.

## Non-goals

This request does not decide which models are organizationally good enough, inspect hidden chain of
thought, make provider self-reports cryptographically independent, or own CI merge policy. Kikan owns
the shared proof vocabulary and Kotei owns enforcement at the delivery gate.

## References

- `mori://shinzui/kikan/okf/use-cases/concepts/UC-8`
- `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-6`
- `mori://shinzui/baikai/okf/improvement-requests/concepts/IR-3`
- `mori://shinzui/kotei/okf/improvement-requests/concepts/IR-2`
- `mori://shinzui/shikigami/repos/shikigami`
