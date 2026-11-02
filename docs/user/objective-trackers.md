---
type: "Guide"
title: "Link objectives to external trackers"
description: "Bind an existing Rei intention, review external proposals, and recover uncertain publication without duplicate actions."
docId: "DOC-17"
tags: ["objectives", "trackers", "rei"]
generated:
  by: process:codex-cli
  at: 2026-11-02T12:39:15Z
---

# Link objectives to external trackers

A binding connects an existing Shikigami objective to an existing Rei intention.
Local execution, the last observed external lifecycle and summary delivery remain
separate. Linking imports no instructions. Later external edits become proposals
that require a local decision; external completion cannot supply acceptance evidence.

An operator first enables a configured connection and grants the intended local
principals access. See [configuration and recovery](../operations/objective-trackers.md)
and [the qualified Rei protocol](../operations/objective-tracker-rei.md).

## Bind an existing intention

Use the configured connection and incarnation, the actual intention ID and a
reviewed field policy. A passive `ReiIntention` reference grants no synchronization
authority. Save this closed envelope as `bind.json`, replacing its coordinates:

```json
{
  "format": 1,
  "operationKey": "bind-reviewed-intention",
  "request": {
    "tag": "RunCommand",
    "contents": {
      "tag": "Bind",
      "contents": [
        "binding-main",
        {"connectionId":"personal-rei","incarnation":"installation-2026-11","resourceId":"INTENTION_ID","providerRevision":"rei-v2-objectives/1"},
        {"revision":"shikigami.tracker-mapping/1","instructions":"ProposeField","lifecycle":"ProposeField","publication":"ProgressSummaries"}
      ]
    }
  }
}
```

```bash
shikigami objectives trackers bind OBJECTIVE --file bind.json --json
shikigami objectives trackers operation OBJECTIVE bind-reviewed-intention --json
shikigami objectives trackers inspect OBJECTIVE --binding binding-main --json
```

Binding requests queue provider reads and return a durable operation. A configured
worker must be running. Reuse the identical key and document after a timeout.
Local decisions such as pause, proposal rejection and application return their
existing command receipt immediately. No CLI option selects another principal.

Inspection shows local status/revision and instructions preview, the external
snapshot and source position, last successful observation time, pending proposals
and delivery state separately. Preview text is bounded and marked `truncated`;
its digest identifies the full retained document. Review full large changes at
the external source before deciding. A preview is not a command document.

## Review external proposals

```bash
shikigami objectives trackers proposals OBJECTIVE binding-main --limit 3 --json
shikigami objectives trackers deliveries OBJECTIVE binding-main --limit 3 --json
```

CLI pages return `next`; pass that exact key with `--after`. HTTP collections use
Relay `first`/`after` or `last`/`before`, default 20 and maximum 100, with at most
three protected previews per response to fit the 16 KiB reply budget. HTTP cursors
belong to one objective, binding and history type.

Use the proposal ID, binding revision and current objective revision from
inspection. Submit this request inside the same `format`/`operationKey` envelope:

```json
{"tag":"RunCommand","contents":{"tag":"ApplyProposal","contents":["binding-main",0,"PROPOSAL_ID",4]}}
```

```bash
shikigami objectives trackers command OBJECTIVE --file apply.json --json
```

Applying instructions goes through the objective owner and invalidates older
instruction checkpoints. A concurrent local edit produces conflict. Explicitly
rebase with `RebaseProposal` and a new reviewed operation, or reject with
`RejectProposal` and a bounded reason. Both take binding ID/revision, proposal ID
and local revision; rejection also takes the reason. Rejection is retained and
repeated identical observations do not offer that version again. External
completed/open/planned facts do not automatically change local completion.

## Pause or reconcile

A pause request is `RunCommand` with `Pause` contents `[BINDING, REVISION]`.
`Resume`, `Detach` and `ChangeMapping` likewise require the current binding
revision. Pausing or detaching preserves accepted attempts and all histories.

A delivered summary can coexist with open local work, and completed local work
can have an undelivered summary. `Unknown` means a Rei action might have committed.
Do not submit another action to compensate. Worker restart, an empty action page
and a copied marker cannot prove non-application.

An explicitly granted reconciler queues `Verify` with `[PUBLICATION_ID, ACTION_ID]`
and waits for its operation. That reads the exact action and retains provider
verification. Then `RunCommand` / `AttestDelivery` takes publication ID, immutable
attempt ID, connection incarnation, exact action ID, publication digest, expected
receipt revision and a reason. The receipt records `OperatorAttested`; a direct
acknowledgement records `ProviderProved`. Replaying the exact attestation returns
the original receipt. Unverified, mismatched or stale evidence is refused.

`Reconcile` takes the publication ID and queues the provider's supported lookup;
for Rei, uncertain authorship remains Unknown until verified attestation.
`SuppressPublication` prevents future sending but preserves an existing Unknown.
[The recovery guide](../operations/objective-trackers.md) explains these limits.
