# 0043. Decision provider wrappers own actual attempt boundaries

Date: 2026-10-25

Status: accepted

## Context

One Shikumi program can call a provider several times and retry internally.
Wrapping an entire invocation misses those attempt boundaries. Handan also has a
process-default model, while a decision must use the exact pinned model and
credential selected for that invocation. Provider evidence and persistence have
different failure semantics from optional telemetry.

## Decision

`Shikigami.Program.DecisionRunner` derives an invocation-local Handan runtime
from the existing runtime configuration, retaining its retry, budget and rate
policies. A private Baikai registry contains one wrapper around the selected
first-class provider. No invocation changes a process-global handler or model.
The wrapper preserves all provider fields, including structured-output support.

Every blocking call and streaming attempt checks its final model/options/request,
profile tuple and evidence requirements before transport. It injects only the
pinned credential, refuses credential/thinking/model/tool escapes, bounds token
and timeout settings, and preserves the program's response schema. Retry attempts
cross the wrapper again and allocate distinct expected-call tokens.

The begin callback commits expectation before dispatch. The finish callback
persists the provider's actual terminal evidence before returning a response or
stream terminal. Callback failures use a separate application exception and
cannot enter Shikumi's provider retry classification. Cancellation leaves an
unresolved expectation; a remote call and its enclosing workflow append are not
an exactly-once boundary.

Application correlation metadata is attached only on compatible APIs. Anthropic
Messages and OpenAI Chat Completions reject arbitrary application metadata under
the existing compatibility contract. Those requests carry the parent evidence
run ID and allocated attempt ordinal; the durable finish callback joins the
opaque attempt token to the independent Baikai call ID. Rechecking the final
request after evidence configuration prevents accidental transport weakening.

## Alternatives rejected

A global handler with mutable credentials would allow concurrent invocations to
cross-talk. Task-level accounting would omit internal calls and retries. Shikumi
billing observations cannot replace complete typed terminal evidence. Converting
persistence errors to provider errors would allow internal retries after an
uncertain accounting write.

## Consequences

The adapter qualifies the project's selected Shikumi 0.4.0.0, Baikai 0.7.2.0 and
pinned Handan revision through actual Predict and streaming paths with fake
providers. Newer released dependencies do not require a migration of the
Flow-facing contract. Future upgrades must preserve these preflight, terminal
and cancellation guarantees.

The runner itself owns no workflow journal. Completed-outcome reuse and durable
run-wide accounting belong to the Flow interpreter and attempt store. A timeout
or exhausted transient provider retry escapes the result step through the
existing bounded transient behavior exception; permanent decode/validation and
policy failures return bounded decision failures.

## References

- [Plan 74](../plans/74-run-shikumi-decisions-through-governed-provider-calls.md)
- [ADR 0041](0041-durable-decisions-bind-program-state-and-preserve-committed-outcomes.md)
- [ADR 0042](0042-decision-admission-intersects-operator-agent-and-pinned-profile-authority.md)
- `mori://shinzui/shikumi/okf/adrs/concepts/ADR-12`
- `mori://shinzui/shikumi/okf/adrs/concepts/ADR-13`
