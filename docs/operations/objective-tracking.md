# Operating durable objectives

Shikigami owns objectives in PostgreSQL. No Rei service or learning-memory
availability is required. Run the normal migrations before starting API and
workers. Use the same database, directory and objective settings for both.

```json
{
  "objectives": {
    "enabled": true,
    "operator": "local-operator",
    "administration": "OwnObjectivesOnly",
    "agentCreation": ["agent_principal_allowed_to_create"]
  }
}
```

Tracking and agent creation default to disabled. The `SHIKIGAMI_OBJECTIVES` JSON
setting supplies the same configuration. `agentCreation` contains declared,
active principal identities; it grants fresh creation before association, not
arbitrary membership or access to unrelated objectives. Existing scoped work
uses its frozen admission. Disabling fresh work preserves internal authenticated
receipt recovery; the HTTP vertical refuses disabled tracking.

Configure HTTP bearer authentication with a stable verified caller and protect
the token as a credential. Anonymous development authentication cannot read or
create objectives or admit associated runs. The local operator is a distinct
principal. `OwnObjectivesOnly` requires membership; `AdministerAll` explicitly
grants administrative access. Members hold owner, coordinator, worker, reader or
completer roles; commands still check current membership, assignment ownership
and exact C13 action authority for agents. Revocation applies to retries too.

Use [the operator commands](operator-cli.md#objectives) and
[the objective API](../api/objectives.md). Public envelopes are format 1, documents
cap at 1 MiB and metadata pages default to 20 with a maximum of 100. History pages
use accepted revision cursors. Do not expose protected payload tables or raw
execution journals through these metadata surfaces.

Preserve exact operation keys and input after timeouts. Accepted receipts are
looked up before stale-version checks and evidence-source recontact, after
current authentication and authorization. A changed payload under one key
conflicts. A fresh conflict requires inspecting and reconciling current state;
never replace an uncertain operation with a new key to assume its effect failed.

Completion checks linked execution and resource owners inside the command
boundary. Logical success can coexist with an unacknowledged superseded attempt.
A positive native objective command can settle that original attempt using its
immutable command receipt and retained dispatch identity. A mutable inspection
has no such receipt: preserve uncertainty until its original output is delivered
or an owning recovery protocol supplies definitive evidence. Availability errors
must remain retryable and cannot become a negative command receipt.

Back up objective state, immutable command payloads and receipts, origin links,
associations, turn admissions, retained scopes and their source stores together.
These are preserved live-only targets; workflow journal GC does not authorize
receipt deletion. No automated retention policy currently removes them. A
missing or corrupt owner fails closed. Do not repair an unresolved source by
zeroing pending counts, manufacturing a receipt or dropping protected rows.

The installed worker checkpoint and ownership providers are
`shikigami-objective-v1`. They retain source cursors and assignment-scoped
preconditions, shared roots, cutoffs and budgets. Workspace-dependent transfers
remain unavailable without the real workspace provider. Finite rootless API
assignments do not imply permission to allocate a new execution root or budget.

Completion requires explicit authorized acceptance of current integrated
criteria. Worker results are observations. Human criteria use completer
attestations; automatic criteria need a trusted producer, which the general
HTTP/worker hosts currently do not install. Cancellation preserves late facts
and is independent of process containment.

Run the disposable [qualification runner](../../tests/objective-tracking/README.md)
in the development shell. It uses loopback scripted model/C13 transports and real
serving binaries, queue and stores. Its separate provider fixture labels
deterministic fencing. It does not qualify real workspace containment, Git
handoff, adaptive coordination, recurring objectives or external Danwa delivery.
