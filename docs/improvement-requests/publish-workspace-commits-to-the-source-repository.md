---
type: Improvement Request
title: Publish workspace commits to the source repository
description: Let an operator grant allow a completed workspace run to publish its validated commit to a named ref of the source repository, so the change is retrievable and a caller can observe that it landed.
timestamp: "2026-11-11T18:18:36Z"
generated:
  by: process:claude-code
  at: "2026-11-11T18:18:36Z"
requestId: IR-23
status: proposed
origin: mori://shinzui/mori
---

# Publish workspace commits to the source repository

## Status

**Proposed; no implementation plan selected.** This request was raised by
`mori://shinzui/mori/masterplans/38-close-uc-2-with-constraint-aware-agent-driven-dependency-upgrades`,
which reviewed Shikigami at commit `86f31b08`. Whether it gates the delivered status of
`mori://shinzui/mori/okf/use-cases/concepts/UC-2` is an open maintainer decision recorded in
`mori://shinzui/mori/plans/283-prove-agent-driven-dependency-upgrades-and-close-uc-2`.

## Problem and current coverage

A workspace run ends with a commit in a private copy under the worker's storage root.
`docs/operations/workspaces.md` states that no push or pull-request operation is provided. The Git
tools are status, diff, and commit. The public HTTP API has no route for a commit, tree, or diff, and
`workspace.integrate` only combines retained commits into another private workspace.

For a dependency upgrade this means the result reaches nobody. A maintainer cannot review or merge
it, and Mori cannot observe that the dependent repository now accepts the new release. A cascade can
order its runs correctly and still leave every repository unchanged.

A grant's base is also one of the operator's listed immutable revisions. That is the right default,
but it means a later run can never start from an earlier run's result without an operator edit.

## Requested change

1. Let an operator grant name a publication target for an agent's workspace commits: a ref pattern
   in the source repository, for example a per-run branch. The caller never supplies a remote, a
   path, or a ref.
2. Publish only the commit that met the run's attested outcome from
   [IR-22](attest-workspace-run-outcomes-in-run-status.md). A run with no required outcome, or one
   that did not meet it, publishes nothing.
3. Treat publication as a protected action under the existing fresh, exact authorization contract,
   with the repository, ref, and commit id as coordinates. Never force-update a ref and never write
   outside the granted pattern.
4. Make publication part of the run's durable outcome. Report the published ref and commit id on the
   status response, and report a failed publication as a run failure with its own reason. Recover an
   uncertain push by reading the ref, not by pushing again blindly.
5. Do not publish for a run that an operator cancelled. State what happens to a run whose caller
   stopped waiting, since the HTTP API has no cancellation: a caller's deadline does not stop a run
   today, and a late publication could surprise it.
6. If pushing to the source is not acceptable for some deployments, offer retrieval instead: an
   operator command or authorized route that exports the commit as a bundle or patch.

Opening a pull request, merging, and releasing the published change are outside this request.

## Acceptance

1. A run with a publication grant that meets its outcome leaves its commit on the granted ref in the
   source repository, and the status response names that ref and commit id.
2. The published commit's tree equals the attested tree from IR-22.
3. A run that fails its outcome, or is cancelled, creates no ref.
4. A run without a publication grant behaves exactly as today.
5. A crash between the push and its receipt recovers to one published ref and one recorded result.
6. An attempt to publish outside the granted ref pattern, or over an existing ref, is refused and
   recorded.

## Dependencies and scope

This depends on [IR-22](attest-workspace-run-outcomes-in-run-status.md) for the attested outcome and
builds on [IR-11](provide-governed-mutable-repository-workspaces.md).
[IR-20](execute-governed-work-through-machine-daemons.md) is related: an enrolled machine
could host the working tree, but it does not by itself define publication.

One further gap is named here and deliberately left out. A later run in a cascade cannot build
against an earlier run's published commit, because a grant's base is immutable and validation has no
network. Solving that needs a decision about how a dependent consumes an unreleased provider, which
belongs with release handling and not with publication.
