---
type: Improvement Request
title: Read pinned, allowlisted repository evidence in durable runs
description: Let a durable Flow or Skill read operator-allowlisted paths of a catalog-admitted repository at one commit resolved and pinned at admission, with bounded reads that each return a content reference, so a scheduled review needs no host-built evidence payload.
timestamp: "2026-11-12T14:30:00Z"
generated:
  by: process:claude-code
  at: "2026-11-12T14:30:00Z"
requestId: IR-24
status: proposed
origin: mori://tan/tan-product-management
---

# Read pinned, allowlisted repository evidence in durable runs

## Status

**Proposed; no implementation plan selected.** This request comes from
`mori://tan/tan-product-management/masterplans/2-add-shikigami-product-management-reviews-and-follow-up`,
which reviewed Shikigami at commit `8d46662a`. It does not block that initiative.
`mori://tan/tan-product-management/plans/11-run-recurring-product-reviews-with-durable-history-and-delivery`
works today with a host timer that builds a commit-pinned evidence snapshot and
submits it as the run payload. If this request is delivered, that plan can drop the
host-side snapshot builder, and the review can run from a native `Schedule` trigger.

## Problem and current coverage

The consumer is a weekly advisory review of a product-knowledge repository. Each run
needs a few dozen Markdown files read from one immutable commit, with a content hash
per file so the review can cite exactly what it saw. It must never read paths outside
an allowlist: the repository holds an ignored private archive and raw interview
captures that must stay out of any prompt.

No durable path supplies those reads today.

- Evidence in the payload is the only path that works now. `POST /agents/{agentName}/runs`
  bounds a payload to 65,536 encoded bytes
  (`shikigami-server/src/Shikigami/AgentRun/Handler.hs`). Plan 90 and ADR 0048 explain
  why, and the bound is reasonable. It does mean that evidence size is capped by the
  journal row size, and an external host has to hold a checkout and build the snapshot.
- A `Schedule` trigger fires with no repository content, so a scheduled agent cannot
  build its own snapshot.
- The bounded `workspace.read` observation provider exists
  ([CAP-12](../capabilities/revision-pinned-tool-overlays.md)), but it is not usable here.
  The one-off commands install `denyAllActionAuthorizer`, so a workspace request fails
  before acquiring its provider. The default durable runtime installs no providers.
  Overlays are admitted only for Skill behaviors. The provider resolves a working tree,
  not a pinned revision.
- [CAP-30](../capabilities/repository-catalog-admission.md) resolves canonical Mori
  identities to an approved immutable base and refuses mutable revision selectors. A
  weekly review of the latest committed state would therefore need an operator to
  approve a new commit every week.
- The practice-review evidence port ([CAP-15](../capabilities/advisory-practice-review.md))
  is the right shape, but its production reader is fail-closed with
  `content-plane-unavailable`. It waits on
  `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-5`, which is proposed.
  `mori://shinzui/kikan/plans/28-author-mori-s-content-plane-revision-pinning-bare-mirrors-and-the-repository-content-api`
  has no completed step.
- [IR-11](provide-governed-mutable-repository-workspaces.md) delivered isolated mutable
  workspaces bound to objectives, with edit, process, Git, and fencing authority. That
  is more authority than a read-only review should hold, and it requires an objective.

## Requested change

1. Provide a read-only repository evidence provider for durable runs, installed by
   worker configuration. A compiled Flow can call it deterministically, without a model
   tool call, through the existing practice-review evidence port or an equivalent Flow
   capability. Until the content plane exists, back it with the catalog-admitted
   repository source that CAP-30 already resolves. The content plane can later serve
   the same port without changing callers.
2. Let a repository policy name an approved ref as well as a fixed commit. The runtime
   resolves the ref to one full commit once, at run admission, and journals it. Every
   read in the run uses that commit, and replay never re-resolves it. Policies that name
   fixed commits keep working as they do today.
3. Enforce an operator-owned path allowlist, and optional denylist, per repository
   policy. Neither an agent declaration nor a run payload can widen it. Keep refusing
   what the `workspace.read` observation provider already refuses: absolute paths,
   traversal, symlinks, Git internals, and binary files.
4. Return a content reference with every read: repository identity, full commit,
   relative path, and content hash, as in the practice review's `ContentReference`
   (`shikigami-core/src/Shikigami/PracticeReview.hs`), which is built from ADR 0008's
   `RepoRef` and `RelativePath`. Journal it with
   the run's evidence. A missing path, a denied path, and an over-budget path each
   return a distinct typed outcome, never empty content.
5. Bound each run by file count, bytes per file, and total bytes, set by the operator.
   Exceeding a bound returns a typed refusal. Never truncate silently.
6. Authorize each read through exact-action authorization, following ADR 0036. Support
   scheduled runs, HTTP-addressed runs, and stream-triggered runs alike.
7. Optionally, expose the same provider to durable Skills as the `workspace.read`
   overlay, pinned to the run's commit and allowlist, so model-driven `read`, `grep`, and
   `glob` see exactly what the Flow-side reader sees.

Configuration syntax, port names, and the shape of the typed outcomes are Shikigami's
to choose.

## Acceptance

1. A scheduled Flow agent whose repository policy names an approved ref reads three
   allowlisted files. Run evidence records one full commit and three content
   references whose hashes the operator can recompute from those blobs at that commit,
   using the hash algorithm Shikigami documents.
2. A commit pushed to the ref after admission does not change any read within that
   run. The next scheduled run resolves the new commit.
3. A path outside the allowlist, a traversal path, and a symlink each return a typed
   refusal. No content from any of them reaches the journal or a model prompt.
4. A run that exceeds its total-byte bound fails with a typed refusal. No partial file
   is presented as complete.
5. After a worker restart mid-run, the run resumes against the same journaled commit
   and returns the same content references, without re-resolving the ref.
6. With `authorization.actions.mode=disabled`, reads are refused before any provider
   acquisition, and the refusal is visible on run status.
7. An agent with no repository evidence configured behaves exactly as before, and no
   read tools appear for Skills that did not request them.

## Dependencies and scope

This builds on [CAP-30](../capabilities/repository-catalog-admission.md) for repository
identity, [CAP-12](../capabilities/revision-pinned-tool-overlays.md) for the bounded
observation semantics, [CAP-15](../capabilities/advisory-practice-review.md) for the
evidence port, and [CAP-7](../capabilities/exact-action-authorization.md) for per-read
authorization. It does not ask for edit, process, validation, or Git mutation
authority ([IR-11](provide-governed-mutable-repository-workspaces.md)), publication
([IR-23](publish-workspace-commits-to-the-source-repository.md)), or a larger HTTP
payload bound. Which paths a review selects stays with the consumer. It can keep a
committed selection manifest in its own repository, which the Flow reads first at the
pinned commit.

## Related question on IR-18

[IR-18](support-recurring-objective-supervision.md) lists as its sixth acceptance case
that "a later relevant event resumes useful authorized work". Plan 87 shipped mandates
as read-only checkpoint supervision that "dispatches no model, worker, tool, external
publication or user notification"
(`docs/operations/recurring-objectives.md`). Is dispatching work from a mandate
intended future scope, or is IR-18 closed at the read-only boundary on purpose? It
matters to this consumer only in combination with this request. A `Schedule` trigger
already covers a fixed weekly cadence once repository reads exist. A mandate that
starts one addressed run per changed checkpoint would add event-driven reviews on top.
