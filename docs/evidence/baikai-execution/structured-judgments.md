# Structured judgment consumer checkpoint

The 2026-11-03 candidate uses the released Baikai 0.10.0.0 / Shikumi 0.5.0.0 /
Kioku 0.12.0.2 cohort at Cabal index `2026-11-03T02:59:02Z`. This is partial
plan 80 evidence. Streaming, the remaining negative/wire fixtures, Linux CLI
consumer checks and immutable package qualification remain open. The
[machine-readable checkpoint](structured-consumer-checkpoint.json) records source
revision, exact selected versions, cohort hash and check counts.

## Actual TypeSafe complete calls

[TypeSafeDecisionSpec](../../../shikigami-core/test/Shikigami/TypeSafeDecisionSpec.hs)
uses normal configuration, a finite immutable decision binding, the application
runner, the public TypeSafe HTTP provider and the public Handan/Shikumi typed
interpreter. Its loopback server accepts public synthetic credentials only.
The six checks pass in the full 680-check core suite:

- One `POST /v1/systemone` uses exact model `jev-latest` without forbidden
  generation defaults. Urgency 0.83 derives true at threshold 0.8. The provider's
  raw category is technical (0.7 versus billing 0.2), while the pinned local
  billing weight of 4 derives billing. Severity retains expected score 1.5,
  distribution 0.1/0.3/0.6, and locally derived level 1, Disruptive.
- The version-two decision outcome roundtrips its rich result, raw snapshot
  and actual call correlation. Exactly one acknowledged receipt is present.
- A fresh call with another program identity, urgency threshold 0.99 and
  default choice weights derives false/technical from the same raw data. Raw
  probabilities and snapshots remain identical to the original true/billing
  call; this is a deliberate new call, rather than replay of an old decision.
- HTTP 403 returns a failure, one failed actual-attempt receipt and no answer.
- Refused terminal persistence returns no success or answer, leaves the
  expectation unresolved, and makes one HTTP call despite enabled retries.
- Synchronized HTTP cancellation propagates `ThreadKilled` with one unresolved
  expectation. Explicit generation controls and missing credentials refuse
  binding before HTTP.

## Structured content and cache

All eight checks in
[BaikaiStructuredContentSpec](../../../shikigami-core/test/Shikigami/BaikaiStructuredContentSpec.hs)
pass. They cover the public full-response codec, Shikumi cache serialization and
a real memoizer hit (one underlying dispatch), optional probabilities,
confidence and method, protected answer rendering, invalid probability data,
snapshot format/count/byte bounds, version-two assistant capture/restore,
unchanged version-one text encoding, and version-three structured user input.
Misplaced user/assistant data refuses replay; data-only output cannot become
successful empty prose. Cache/replay does not mint provider evidence.
The new byte bound applies only to the new assistant format; a large historical
text snapshot still decodes and restores through its original reader.

## Durable queue and worker restart

Both checks in
[TypeSafeDecisionWorkflowSpec](../../../shikigami-core/test-postgres/Shikigami/TypeSafeDecisionWorkflowSpec.hs)
pass against disposable PostgreSQL:

1. Enqueue the proof Flow through the real run queue. Stop the first worker
   before memory recording, after the judgment result is committed. Close its
   stores and runtime, then retry the queued job with an empty model catalog,
   no providers, a changed current program/threshold and the retained original
   result codec. The run completes with identical raw and rich outcome JSON,
   one actual-attempt receipt and one total HTTP request.
2. Stop before the judgment-result body, remove the pinned binding, and restart.
   The pending decision refuses before dispatch; the HTTP counter stays zero.

The new finite judge steps are guarded by
`shikigami-structured-judgments-v1`. Existing generative programs omit the new
capability field and keep the old outcome envelope when no answer is present.
The pure conversation constructor rename retains assistant format number one
and adds no durable step.

## Regression and build boundary

Core 680, agent 37, serial PostgreSQL 545, server 105, migration smoke 11 and
serial worker 281 checks pass. The full committed native gate passes all 177
conformance assertions with no generated drift. Its
[native diff](structured-keiro-diff.json) classifies the judgment patch as
additive, and the [stored-data replay verdict](structured-keiro-replay-impact.json)
is neutral. These declaration-level verdicts supplement the consumer fixtures;
they do not certify arbitrary opaque retained data. Haskell conventions and
their 13 regression/mutation tests pass. The optional workspace fixture compiles
on Darwin; its Linux runtime is not requalified by compilation.

The successful solve exports 387 runtime packages and seven immutable
repositories to `nix/qualification`. All five role attributes evaluate through
`nix build --dry-run`. No fresh immutable build or outside-checkout installed
asset qualification is claimed by this checkpoint.

## Outstanding acceptance

Released Shikumi rejects decision outputs in both `streamPredict` and the
router's `Stream` branch. Its streaming parser also omits explicit decision
settings. FRIC-49 is promoted to
`mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-5`; no downstream
router or parser bypass is used. M7/M8 remain open until a qualifying released
consumer proves complete/stream parity and the remaining plan criteria.

These local synthetic fixtures make no remote TypeSafe request and establish
no paid-model or production service qualification. The runnable operator
example is documented in [typed Flow decisions](../../shikumi-flow-decisions.md).
