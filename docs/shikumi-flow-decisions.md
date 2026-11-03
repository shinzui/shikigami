# Typed Shikumi decisions in durable Flows

The compiled `shikumi-decision-example` Flow triages a request with alias `triage`.
Its typed result either returns immediately or runs a two-node investigation with
alias `investigate`. Investigation returns a result or proposes specialist routing.
The Flow validates that proposal against its journaled candidate catalog before
using governed delegation. No-match and ambiguous proposals create no children.
The ordinary agent lifecycle dispatches declared sinks after a successful Flow.

The implementation is in [Flow.Decision](../shikigami-core/src/Shikigami/Flow/Decision.hs),
[the example](../shikigami-core/src/Shikigami/Flow/ShikumiDecisionExample.hs), and
[its typed programs](../shikigami-core/src/Shikigami/Program/Decision/Examples.hs).
The [proof declaration](../agents/proof/shikumi-decision-example.dhall) grants both
aliases and a bounded specialist set. Its request payload is
`{"request":"Review the architecture practice"}`. Summaries and confidence are
validated result fields; confidence must be finite and between zero and one.

## Configure the operator catalog

The operator catalog grants finite, versioned model bindings. The agent's
`decisionModels` list and pinned sanctioned profile further restrict that grant.
Neither a payload nor model output can supply a credential or extend authority.
An empty catalog grants no decision models. All declared slots are admitted
together before triage, so a profile permitting only triage refuses the whole
example before any provider call.

For a deterministic database-backed smoke run, use this YAML configuration:

```yaml
behavior:
  provider: stub
  decisionModels:
    - alias: triage
      version: "1"
      bindingId: proof-triage
      bindingVersion: "1"
      provider: stub
      model: stub-triage
      thinking: default
      max_tokens: 1024
      timeout_ms: 30000
    - alias: investigate
      version: "1"
      bindingId: proof-investigate
      bindingVersion: "1"
      provider: stub
      model: stub-investigate
      thinking: default
      max_tokens: 2048
      timeout_ms: 30000
```

The private decision stub returns typed JSON through actual Handan/Shikumi
dispatch. Triage selects investigation; both investigation nodes use
`stub-investigate`. Its evidence claims requested identity only. It does not
claim an independently observed remote model.

For HTTP execution, the selected Baikai catalog includes these two models:

```yaml
behavior:
  decisionModels:
    - alias: triage
      version: "1"
      bindingId: anthropic-triage
      bindingVersion: "1"
      provider: anthropic
      model: claude-haiku-4-5
      thinking: default
      max_tokens: 1024
      timeout_ms: 60000
    - alias: investigate
      version: "1"
      bindingId: anthropic-investigate
      bindingVersion: "1"
      provider: anthropic
      model: claude-sonnet-4-6
      thinking: default
      max_tokens: 4096
      timeout_ms: 120000
```

Supply `ANTHROPIC_API_KEY` separately. `openai` selects Chat Completions and
`openai-responses` selects Responses; both use `OPENAI_API_KEY` and require an
exact ID from their respective generated catalogs. Unknown fields, custom model
IDs, unsupported thinking preferences, and credentials embedded in catalog
entries are refused. `thinking: default` explicitly requests provider defaults;
the pinned profile must permit defaulted thinking. Catalog JSON can also be
supplied through `SHIKIGAMI_BEHAVIOR_DECISION_MODELS`. This setting is redacted
in configuration diagnostics, including malformed nested input.

HTTP bindings also accept optional `base_url` and `cache_retention` fields.
`base_url` uses the same HTTP(S) endpoint policy as `behavior.base_url`: it cannot
contain credentials, a query or a fragment. The credential still comes from the
selected provider's explicit credential setting. A plaintext override requires a
profile permitting the actual `http` tuple. Stub bindings refuse endpoint overrides.
`cache_retention` accepts `none`, `short` or `long`; unsupported model/API pairs
fail configuration. Both settings join the immutable binding digest. Omission
preserves the existing endpoint and options, including historical descriptor
identity. Change the binding version when changing these settings and retain old
bindings needed by pending work. A program cannot override an explicitly pinned
retention, including `none`. A marker requests caching; it does not prove a hit.

For example, an Anthropic binding can add `cache_retention: short`, or use an
intentional gateway with `base_url: https://gateway.example/v1`. Configuration
checks contact neither endpoint. The catalog remains redacted as one setting in
effective configuration reports; admitted descriptors expose its binding identity
and endpoint class through the existing inspection paths.

Save the chosen YAML as `decision-models.yaml`. Use the normal migration/bootstrap
setup and the same database for both commands. The proof directory contains the
declaration and its declared specialists; agent loading reads one directory rather
than recursively discovering manifests. Enqueue a run and process it:

```bash
export SHIKIGAMI_AGENTS_DIRECTORY=agents/proof
cabal run shikigami -- --config decision-models.yaml enqueue-run shikumi-decision-example \
  --payload '{"request":"Review the architecture practice"}' \
  --key decision-example-1
cabal run shikigami-worker -- --config decision-models.yaml
```

The enqueue command resolves the agent by name from the configured agent set.
The one-off `shikigami-agent-run` shares decision services but currently supplies
a null trigger payload, so this request-taking example is exercised through the
queue or the PostgreSQL acceptance suite. The database-free behavior command
cannot interpret durable Flow capabilities.

## Run the supplied-ticket judgment example

The compiled `shikumi-judgment-example` Flow accepts
`{"ticket":"Checkout is unavailable."}` and uses only the `judge` decision alias.
It returns urgency, category and severity with their probability data. The
[proof declaration](../agents/proof/shikumi-judgment-example.dhall) grants that
alias and no delegation or sinks. Configure a matching binding:

```yaml
behavior:
  provider: stub
  decisionModels:
    - alias: judge
      version: "1"
      bindingId: typesafe-judge
      bindingVersion: "1"
      provider: typesafe
      model: jev-latest
      thinking: default
      timeout_ms: 30000
```

Supply `TYPESAFE_API_KEY` privately, or set
`credentials.providers.typesafe.api_key` in private configuration. A manual
loopback fixture can additionally set `base_url` and use only its public
synthetic credential. Configuration checks make no request. TypeSafe rejects
generation controls, including `max_tokens`, sampling and explicit reasoning
`none`; an incompatible finite token policy refuses before transport. The
legacy text/tool model selection cannot select this judgment-only model.

After the normal database bootstrap, save the YAML as `judgment.yaml` and use
the existing queue/worker entry points:

```bash
export SHIKIGAMI_AGENTS_DIRECTORY=agents/proof
cabal run shikigami -- --config judgment.yaml enqueue-run shikumi-judgment-example \
  --payload '{"ticket":"Checkout is unavailable."}' --key judgment-example-1
cabal run shikigami-worker -- --config judgment.yaml
```

This makes a real TypeSafe call when pointed at its public endpoint. The
deterministic acceptance tests instead use a local HTTP server and synthetic
answers. The registered program pins an urgency threshold of 0.8, category
weights of 4 for billing and 1 for technical, and severity cuts of 0.75 and
1.75. The fixture's category probabilities are billing 0.2 and technical 0.7:
the raw provider choice remains technical while the local weighted result is
billing. Neither distribution nor optional confidence/method observations are
rewritten to match the local answer.

Structured outcomes retain the raw answer separately from the derived result
and actual call receipt. Committed outcomes replay after credentials and model
bindings are removed, using retained codecs and the original result. New calls
under changed settings require a new program identity. New judgment steps use
the `shikigami-structured-judgments-v1` patch; historical generative steps keep
their original labels and result envelope.

The released Shikumi runner currently refuses judgment streaming before
transport. `mori://shinzui/shikumi/okf/improvement-requests/concepts/IR-5`
requests complete/stream typed-result parity and acknowledged atomic structured
events. The example uses complete calls; streaming acceptance remains open.

## Register a new decision

Register a typed `Program i o`, input/domain validators, a durable result codec,
and immutable code/schema/validator/parameter/derivation identities. Put
demonstrations in serializable `Params`; the selected upstream signature-level
existential does not expose the encoders needed to commit typed demonstrations.
The registry retains effective instructions, demonstrations and local derivation
state. Changing any of them requires a new immutable registration. Reusing a
program ID and version with changed state is refused.

Declare the finite slot inventory on `FlowDef`, add a closed `DecisionLabel`,
and map it to literal preparation/result labels. A Flow calls
`decide staticStep authorizedAlias typedInput`; it never receives IO, a provider
handler or credentials. The whole-Flow policy pins every slot before the first
call, including a branch that has not yet executed. Decision-only Flows declare
`requiresDefaultModel = False`; flows using Routing or PracticeReview keep the
default-model profile check.

Pure output validation precedes the next protected effect. A proposed specialist
route additionally needs strict `Router.Decision` decoding and validation against
the same journaled catalog and declaration. Delegation still rechecks current
authority at child creation. A model-supplied agent or sink identifier grants
no permission.

## Replay and version retention

The new segment is guarded by `shikigami-flow-decisions-v1`. An old patch snapshot
keeps the old interpreter and cannot enter decision steps. The static labels and
envelope contracts are recorded in [workflow versioning](workflow-versioning.md).
Each slot may run once per generation. Repeating a slot is refused. Unbounded
decision loops need a rotating workflow with `restoreSeed` and `continueAsNew`.
Changing the declared body requires the normal declaration, scaffold, conformance
and evolution gate.

Retain historical pure result codecs independently of executable programs. A
committed outcome decodes its entire original validated result through the
recorded codec, even if its executable or model binding is retired. It does not
run a current validator or derive another answer from stored confidence. Unknown
historical codecs fail explicitly without calling a provider.

Pending work requires the exact pinned program/state and model binding. Keep
historical immutable registrations and use `retainModelBindings` for old binding
versions without expanding new-run authority. Operator configuration supplies
the active catalog; it does not automatically retain retired credentials. If a
pinned version is unavailable, execution returns a bounded refusal before
dispatch. A new alias version or process default never substitutes for it.

Workflow replay preserves decisions. Deliberately re-deriving an answer from
upstream evidence under new thresholds is a separate operation with a new
program/derivation identity. Future probability or Jev adapters require qualified
versioned integrations beyond the qualified TypeSafe complete path above.
Probability and confidence describe judgment; they do
not prove provider identity, usage, or terminal accounting.

## Evidence and crash windows

An uninterrupted investigation records one triage attempt and two investigation
attempts. Invocation bindings identify the parent workflow, generation, slot,
program/state, selected model and policy. The durable attempt ledger records an
expectation before each actual provider dispatch, then the terminal provider JSON
and versioned Shikigami compliance facts before success can be journaled. The
ordinary run report is unsigned; it does not fabricate a reviewed-artifact binding.
Call-level profile assessment uses the same evaluator as sanctioned evidence.

Completed results make no new calls on replay. A crash after a provider call but
before the workflow result append may repeat execution. Every actual attempt
gets another ID and remains visible; this is not exactly-once transport. An
unresolved expectation or terminal persistence failure cannot establish complete
accounting. Unknown token/cost/lineage facts remain explicit uncertainty. Reports
are bounded to 10,000 attempts, with detail pages of at most 200.

The public `Shikigami.Decision.Evidence` API provides `readDecisionReport`,
`listDecisionCalls`, and finalization over the PostgreSQL store. No additional
report HTTP route is introduced by this feature.

Run the executable acceptance and evolution checks with:

```bash
cabal test shikigami-core-postgres-test \
  --test-options='-j1 -p "durable typed decisions"' --test-show-details=direct
just keiro-gate 436e9f8
```

The PostgreSQL suite uses isolated migrated databases and actual workflow
journals. It covers mixed models, retained rich results and local derivation,
pending pins, lost appends, evidence faults, routing authority, old patch
snapshots, and child/sink deduplication.
