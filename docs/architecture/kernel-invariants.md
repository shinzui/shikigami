# The kernel's invariants, audited

This is the audit EP-11 M3 of MasterPlan 22 asks for
([plan 136](../plans/136-freeze-the-v1-api-baseline-with-a-surface-inventory-and-compatibility-checks.md)).
The MasterPlan states eight invariants, K1 to K8, that hold in every composition and every
trust tier. For each one this page names the code that enforces it, the test that fails when
the enforcement is removed, and evidence from a real run in the stock composition and in the
Kikan distribution. Where an invariant holds only partly, or only by convention, the section
says so and names the gap's owner. The second part cites the acceptance evidence of the
initiative's three requirements.

Audited on 2026-11-17 at the tree of commit `b931599f`.

The action record is the common evidence. Every durable run appends its admission, each
authority decision, each effect and its finish to `shikigami.action_record`, and
`shikigami record check --run <id>` (`Shikigami.Record.Invariant.checkRun`) verifies K1, K2
with K3, K4, K5, K6 and K8 from that record alone. K7 holds by construction and is not
decidable from the record.

**The two runs cited below** ran `agents/proof/portable-note.dhall` unchanged on one
disposable PostgreSQL with the stub behavior provider (plan 135, M6):

* stock, `shikigami-agent-run` under `trust.tier=local-operator`, run `0d24eabf-213e-5af8-9b82-19585c8fc294`;
* distribution, `kikan-shikigami-agent-run` under the contained tier with the loopback
  fixture Kikan-En and `kikan-shikigami-worker` publishing to `stub-kawa`, run
  `cfde3961-6722-5a02-b409-144fc9caa5be`.

For both, `record check` printed `K1 K2/K3 K4 K5 K6 K8 hold (K7 by construction)`, with 4
events and 5 events and one effect each paired with a decision and a step. The disposable
database was dropped afterwards; the record lines are copied into plan 135's M6 entry.
EP-8 M3's earlier pair (runs `d7c18bad-3ed9-52d9-9ece-8cf6919c1485` and
`a5e632c4-93f7-55ed-bf23-192a3b81228c`) used a real model, `gpt-5.4-mini`, and passed the same
check.


## K1 Principal

*Every run and every external action carries a principal. A paused principal is refused
before any protected effect.*

* **Enforced by** the directory port (`Shikigami.Directory`): `identityAdmission` admits a
  declared principal at enqueue and, since plan 135 M6, at a deployment-tier one-off run;
  `identityLifecycleAdmission` gates every outbox dispatch (`Shikigami.Sink.dispatchOutbox`)
  and the worker's drain gate (`lifecycleRefusal` in
  `shikigami-workers/src/Shikigami/Agent/RunJob/Worker.hs`). Every record event carries a
  principal, and `run.admitted` records the directory's answer as `lifecycle`.
* **Tests:** `RecordInvariantSpec` "K1: an event without a principal", "K1: a second
  principal" and "K1: a paused principal acted"; `DirectorySpec` "paused and deactivated
  principals are skipped" and "configured mode without a valid snapshot fails closed";
  `WorkerSpec` "drain gate enforces every configured lifecycle decision".
* **Evidence:** the distribution run admitted `agent_01h000000000000000portable` with
  `lifecycle: active`; the stock local-operator run is `unmanaged`, acting for the operator.
* **Partial:** both compositions read a file directory. A live Meibo source is future
  binding work (MasterPlan 22, Kikan requirements).


## K2 Authority

*Exactly one authority port decides every external action immediately before the effect,
and it fails closed.*

* **Enforced by** `Shikigami.Authority`: one `Authority` per run, selected by
  `authorization.actions.mode` among the composed packs' adapters
  (`Shikigami.Authority.Configured.buildConfiguredAuthority`) or the local-operator
  authority; `denyAll` when nothing is composed. An outbox delivery is decided again at
  publish, under its run.
* **Tests:** `AuthoritySpec` "deny-all refuses every action and names no source" and "a
  failed append turns an allow into a refusal"; `RecordInvariantSpec` "K2/K3: an effect with
  no decision, a refusal, or a later decision"; the binding's `AuthoritySpec`
  (`toAgentAction` over every `Action` constructor).
* **Evidence:** the stock run's `authority.decided emit_output` is `decidedBy: operator`; the
  distribution run's two are `decidedBy: service:kikan-en`, at enqueue and at publish.
* **Partial:** Kikan-En names no action for a declared tool or a coding-agent launch, so the
  distribution refuses them (`mori://shinzui/kikan-en/improvement-requests/IR-5`). This is
  fail-closed, not a hole.


## K3 Record

*Every decision and every effect is appended to the action record before the effect
proceeds. The record is stored where the agent cannot write.*

* **Enforced by** `Shikigami.Authority.recorded`, which appends each decision before
  returning it and turns a failed append into a refusal; effects append `output.delivered`
  after the delivery, inline (`deliver-outputs`) or, since plan 135 M6, from the outbox
  publisher (`outbox-publish`). The record lives in `shikigami.action_record` for durable
  runs and an append-only mode-0600 file for database-free ones; no behavior or tool has a
  capability that writes it.
* **Tests:** `AuthoritySpec` "every decision appends exactly one event, refusals included";
  `RecordSpec` "the file store is mode 0600, append-only and readable by query";
  `RecordInvariantSpec` "the delivered entry names the exact decided action";
  `SinkIntentSpec` "an intent carries its enqueuing run, and one without it still decodes".
* **Evidence:** both runs' `output.delivered` entries pair with their decision.
* **Gap closed in this audit's window:** before plan 135 M6 an outbox delivery left no
  effect in its run's record (`5bd2c94b`). Projecting the record into attestation evidence is
  the attestation plan's (`docs/plans/52-signed-attestation-read-api-and-uc-8-conformance.md`),
  by the user's decision of 2026-11-17.


## K4 Pinned artifact

*A run pins the exact declaration, skill and playbook it executes. An edited file affects
only later runs.*

* **Enforced by** the agent-run workflow's `lookup-agent` step, which journals the
  declaration, and `run.admitted`'s `declarationDigest`
  (`Shikigami.Agent.RunRecord.declarationDigest`); a playbook pins its file the same way
  (ADR-128).
* **Tests:** `RecordInvariantSpec` "K4: no admission, or one with no digest".
* **Evidence:** both runs' `run.admitted` carry a `declarationDigest`; EP-8 M3's pair pinned
  the same digest under both compositions.


## K5 Bounds

*Every run spends under a resource root with deadlines and budgets. Unknown usage is
recorded as unknown, never as zero.*

* **Enforced by** `Shikigami.Execution.Resources` and its store: a run that may mutate a
  repository is enrolled under a root sized by its grant's budget; settlement records
  `UnknownUsage` with its reason rather than a zero; every run has a lease
  (`timeoutSeconds` in `run.admitted`).
* **Tests:** `RecordInvariantSpec` "K5: neither a root nor a lease"; `ExecutionResourcesSpec`.
* **Evidence:** both runs record `timeoutSeconds` and `root: null`, a lease without a root,
  because neither may mutate a repository.
* **Partial:** a run that does not mutate a repository spends under a lease, not a root, and
  cost capture for ordinary runs is deferred to its owning plan; a supervised root may leave
  cost unbounded while its work, attempts and tokens are finite (ADR-121, amended by the
  user on 2026-11-16).


## K6 Durability

*Effects happen in journaled steps. A completed step is never rerun, and an effect whose fate
is unknown is never retried automatically.*

* **Enforced by** keiro's journal (a recorded step is read back on replay), the effect's
  `step` and `effectKey` in the record, the outbox's delivery receipts (a delivered receipt
  is never sent again), and the coding-agent and process attempts, which reattach rather
  than relaunch.
* **Tests:** `RecordInvariantSpec` "K6: an effect outside a step, and a repeated effect";
  `CodingAgentSpec` "an intent without a launch record is uncertain, never relaunched";
  `ProcessLocalSpec` "a worker that dies mid-attempt is followed by a reattach, not a second
  launch"; the distribution's `OutputDeliverySpec` (receipt-gap redelivery is deduplicated
  downstream).
* **Evidence:** the stock effect names step `deliver-outputs`, the distribution's
  `outbox-publish` with effect key `outbox:<message id>`.
* **Partial:** an outbox row whose receipt is `Attempting` when its worker dies is published
  again; it relies on the downstream service deduplicating on the intent's key (Kawa's
  `(source, source_event_id)`), which holds for the binding's adapters but is a property of
  each adapter, not of the kernel.


## K7 Evidence

*Observed content is evidence, never instruction*
([ADR-112](../adr/0112-observed-content-is-evidence-and-never-instruction.md)).

* **Enforced by** construction: observed content (a stream envelope, a tool result, a
  conversation message, an observed objective) reaches a model only as data in the behavior
  payload, and every protected choice (recipient, repository, scope, owner) comes from the
  declaration or a checked value, never from observed text.
* **Tests:** the initiative pack's "planted instructions change no repository, recipient,
  owner or scope" and the watchdog's "IR-19 case 6: planted instructions cannot choose subject
  or recipient".
* **Not decidable from the record**, which `record check` says as "(K7 by construction)".


## K8 Admission

*Run admission is idempotent on its key.*

* **Enforced by** the run-job keys (`Shikigami.Agent.Run.Key`, `Shikigami.Trigger.Enqueue`)
  and the keiro inbox for stream and event intake, which dedupes on the integration message
  id.
* **Tests:** `RecordInvariantSpec` "K8: two runs admitted under one key";
  `EnqueueHardeningSpec` "the same logical event enqueues one stable idempotency key".
* **Evidence:** both runs record their `idempotencyKey`; plan 135 M5's acceptance saw the
  events consumer refuse a second delivery of one message id across topics.


## The three requirements

* **Routine agents are easy.** Accepted by EP-9 on 2026-11-15: `repo-digest` ran by hand in
  keiro and on a local schedule under `shikigami-local up` (three runs), and `readme-keeper`
  committed in fsrs-hs (MasterPlan 22, Progress).
* **Portability.** Accepted by EP-10 M6 on 2026-11-17: the two runs above, one declaration
  unchanged under both compositions with K1 to K8 holding in both.
* **Architectural.** Not yet accepted. The keiro modernization campaign ran for real on one
  repository: koyomi, run `aa2b77a1-…`, EP-7 M3 on 2026-11-17, with no change to
  `shikigami-core`. The second repository comes from EP-7 M4's batches. The kizashi pilot
  was stopped on 2026-11-16 (EP-7 M2). The declaration baseline (EP-11 M2) followed the
  koyomi run, and the kernel baseline (EP-11 M4, 2026-11-18) does not depend on this
  requirement.


## Gaps against an invariant

None blocks the kernel baseline in the sense of plan 136's M4: every partial entry above is
either fail-closed (K2), recorded honestly (K5's unknown usage, K3's projection), or a
property of each adapter (K6's redelivery). They are listed so the freeze does not hide them.
