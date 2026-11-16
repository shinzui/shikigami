# Operating unrequested work

An agent can read what `activity.v1` already carries, notice work nobody asked for and
propose it. This guide covers enabling that, sizing it, governing it and stopping it. The
person-facing side is [Unrequested work](../user/unrequested-work.md).

The proposer observes and proposes. It never acts without a person or a standing policy
you installed. A message that says otherwise changes nothing: authority comes from your
configuration, the recorded principal and your policy rows
([ADR 0112](../adr/0112-observed-content-is-evidence-and-never-instruction.md)). Text an
agent observed is stored nowhere but the decision's own journaled input: the ledger, asks,
objectives and metrics hold coordinates and digests.

## Enable it

Unrequested work ships in the flow pack `packs/flow-pack-initiative`, and runs from the
`kikan-shikigami` distribution, which composes it: `kikan-shikigami-consume-stream` decides
at intake which observed records are worth an evaluation, `kikan-shikigami-worker` runs the
proposing flow, and `kikan-shikigami proposals` is the operator's view. The stock
`shikigami-*` executables have none of it: they refuse the `initiatives` key as unknown, the
stock worker refuses the proposer's manifest (`unknown flow propose-work`), the stock stream
consumer treats a matching record as an ordinary trigger, and `shikigami proposals` is not a
command.

Observation is off until a principal has an observer allowance. Add one under the
`initiatives` key or the `SHIKIGAMI_INITIATIVES` environment variable:

```json
{
  "observers": [
    {
      "principal": "agent_shikigami_proposer",
      "sources": ["intercom-conversation", "meeting-transcript"],
      "minimumExcerptLength": 40,
      "evaluation": {
        "limits": {
          "ActiveWork": 1,
          "ModelAttempts": 3,
          "Tokens": "unbounded",
          "CostMicroUsd": "unbounded"
        },
        "cutoff": 900
      },
      "evaluationsPerWindow": 200,
      "proposalsPerWindow": 20,
      "notificationsPerWindow": 20,
      "window": 86400,
      "proposalExpiry": 604800,
      "rejectionSuppression": 1209600,
      "notices": { "kizashiRecipient": "recipient_engineering" }
    }
  ]
}
```

Then:

1. Copy `packs/flow-pack-initiative/agents/proposer.dhall` into `agents/` and change its stream `source` to
   `external/intercom` or `external/transcripts`. Give it the principal you listed, active
   in the directory. Observers require a verified principal.
2. Add the principal to `objectives.agentCreation`, or acceptance is recorded as refused
   with `creation-denied`.
3. Add a model under the `propose` alias in `behavior.decisionModels`. Assessment calls
   are real provider calls, billed to the evaluation root.
4. Configure `workspaces`. The proposer is offered only repositories in that catalog, and
   with no catalog every candidate is a `no-repositories` skip. The model sees repository
   identities and never their source locators.
5. Check the approval channel. Asks go where the run's approval policy says.
6. For admission notices, grant the principal the Kizashi sink in the C11 grant table.

## Size the allowance

An evaluation is one model call, retried at most as `ModelAttempts` allows. The envelope
must name `ActiveWork`, `ModelAttempts`, `Tokens` and `CostMicroUsd`, and cost must be
`unbounded`, because a root admits a model attempt only when all four are named and no
ceiling can be reserved for cost before a call. A finite `Tokens` limit requires the model
binding to set a maximum output.

`cutoff` bounds the evaluation, not the wait for a person: acceptance after it still works.
`evaluationsPerWindow` bounds spend, and is counted when a run opens, so queued work holds
no slot. `proposalsPerWindow` and `notificationsPerWindow` bound how much attention the
agent can ask for. `proposalExpiry` is how long an ask waits before it expires, and
`rejectionSuppression` is how long a rejected or expired subject stays quiet.

Every message that matches the agent's stream trigger runs the pure pre-filter inside the
inbox transaction. One that fails costs one row and no workflow. One that passes costs a
workflow even when the window turns out to be full, so keep the stream match narrow.

## Standing policies

Without a policy, every proposal waits for a person. A standing policy admits covered
proposals without one. Write the terms in a file (see
[`tests/initiative/policy-fixture.json`](../../tests/initiative/policy-fixture.json)):

```bash
cabal run kikan-shikigami:exe:kikan-shikigami -- proposals policy install --file policy.json --json
cabal run kikan-shikigami:exe:kikan-shikigami -- proposals policy list --json
cabal run kikan-shikigami:exe:kikan-shikigami -- proposals policy revoke POLICY_ID --expected-revision 0 --json
```

These act as the configured local operator. Install refuses a policy that could never
admit: a principal absent from `objectives.agentCreation`, a repository outside the
catalog, a coordinator that is not a loaded, enabled `Flow` or `CoordinatingSkill` with a
declared identity, an envelope that cannot pay for a model attempt, a total below the
per-objective amount, or an expiry past `maximumPolicyLifetime` (30 days unless you set it
beside `observers`).

A changed policy is a new policy and a revocation of the old one, so an admission's digest
always names the exact terms it ran under. Totals are promises rather than measurements:
each admission takes one whole per-objective envelope, and a reservation stays consumed
even if its admission fails. Reclaim capacity by installing a new policy.

A policy grants the coordinator nothing. Its workspace grants, sink grants and action
authorization decide what can leave the workspace, and the objective's instructions stop at
a reviewable artifact.

## Read the ledger

```bash
cabal run kikan-shikigami:exe:kikan-shikigami -- proposals inspect --json
cabal run kikan-shikigami:exe:kikan-shikigami -- proposals inspect --fail-when-exhausted
cabal run kikan-shikigami:exe:kikan-shikigami -- proposals list --status pending --json
cabal run kikan-shikigami:exe:kikan-shikigami -- proposals candidates --principal agent_shikigami_proposer --json
cabal run kikan-shikigami:exe:kikan-shikigami -- proposals admissions --json
```

`inspect` lists every configured observer, so a quiet one shows zero usage and an absent one
is simply not there, and every live policy with its remaining totals. A full window is the
`exhausted` state, and `--fail-when-exhausted` exits nonzero so a periodic check can alarm
on it. It is deliberately not a health probe: restarting does not refill a window
([ADR 0020](../adr/0020-readiness-covers-only-what-restarting-can-fix.md)).

These reads need the database, and reveal no excerpt because the ledger stores none.

Candidates carry a verdict (`skipped`, `evaluating`, `proposed`, `not-actionable`) and a
reason. `owner-unknown` means the ledger could not answer who owns a subject, which is worth
investigating. A candidate stuck at `evaluating` belongs to a run that failed or has not
finished: a root refusing the model attempt fails its run, so check `shikigami runs`.

## Stop it

- A proposal: answer its ask with `--reject`, which also suppresses the subject.
- Further admission: `proposals policy revoke`. The next admission refuses at its fresh
  read, and the proposal parks for a person.
- All observation by a principal: remove its allowance and restart the stream consumer and
  workers. Runs then journal `no-observer-allowance`, and that agent's jobs return to an
  ordinary trigger path.
- Admitted work: revocation does not touch it. Cancel the objective with `shikigami
  objectives command`, and cancel its root with `shikigami resources`.

## Prune

Skips are bounded rows but they accumulate. Remove old ones a batch at a time, as the local
operator:

```bash
cabal run kikan-shikigami:exe:kikan-shikigami -- proposals prune --before 2026-10-01T00:00:00Z --batch 1000 --json
```

This only deletes `skipped` and `not-actionable` candidates, never an `evaluating` or
`proposed` one, and never a proposal or admission.

## Metrics

| Instrument | Attributes |
| --- | --- |
| `shikigami.stream.dispositions` | `pack`, `verdict`, `skip.reason` |
| `shikigami.pack.events` | `pack`, `event`, and one of `verdict` with `skip.reason`, `status`, `stage`, `refusal.kind` |

`shikigami.stream.dispositions` counts what stream intake decided for a matched record:
`evaluating` or `skipped`. The proposing flow counts on `shikigami.pack.events`, with
`event` one of `candidate` (a skip or `proposed`, with `verdict` and `skip.reason`),
`proposal` (`status`), `admission` (`stage`) and `refusal` (`refusal.kind`). They replace
`shikigami.initiatives.candidates`, `.proposals`, `.admissions` and `.refusals`.

No attribute carries an identifier, excerpt or error text. Alert on `event="refusal"` and on
`proposals inspect --fail-when-exhausted`. A jump in `shikigami.stream.dispositions` with `skip.reason` of
`decision-refused` suggests a model answering outside the offered choices.
