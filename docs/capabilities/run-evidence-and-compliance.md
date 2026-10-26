---
type: "Capability"
title: "Run evidence and compliance records"
description: "Collect correlated call evidence, evaluate execution compliance, and persist a checked lifecycle with guarded queries."
capabilityId: "CAP-14"
provider: "mori://shinzui/shikigami"
status: "shipped"
stability: "experimental"
since: "unreleased"
packages: ["shikigami-core", "shikigami-migrations"]
interface: ["Shikigami.Attestation.Evidence", "Shikigami.Attestation.Compliance", "Shikigami.Attestation.EvidenceStore.findRunEvidence", "Shikigami.RunEvidence.Catalog"]
tags: ["run-evidence-and-compliance"]
generated:
  by: "process:shikigami-capabilities-bootstrap"
  at: "2026-10-10T15:55:22Z"
requires: ["CAP-13"]
evidence:
  - kind: test
    resource: "shikigami-core/test-postgres/Shikigami/RunEvidenceSpec.hs"
    proves: "Call/retry/child roll-up, compliance mutations, sealing preconditions, transactional rollback, and query/rebuild fencing."
  - kind: test
    resource: "shikigami-core/test/Shikigami/AttestationContractsSpec.hs"
    proves: "Evidence-strength vocabulary and canonical payload bytes/digests."
  - kind: module
    resource: "shikigami-core/src/Shikigami/Attestation/Envelope.hs"
    proves: "Unsigned envelope contract and the explicit absence of implemented signing."
---

# Run evidence and compliance records

## Provides

Library consumers can collect model trace evidence with run/attempt/retry correlation, include delegated child evidence, and evaluate model, endpoint, effort, limits, reviewed artifact, and evidence-strength requirements. The checked RunEvidence lifecycle prevents premature sealing or reopening terminal evidence. Lifecycle append and rich SQL payload writes share a transaction, and queries honor projection fences.

## Adopt

Typed Flow decisions additionally maintain their own durable actual-attempt
ledger and versioned compliance facts. Its library query API and uncertainty
limits are described in [CAP-21](typed-flow-decisions.md). This shares the
compliance evaluator while retaining a separate accounting owner; ordinary
decision reports remain unsigned.

Embed the evidence collector and compliance functions in an evidence-enabled runtime. Register the shared evidence catalog and use its store/query interfaces after applying migrations. The PostgreSQL suite includes multi-call, retry, child, rollback, and restart scenarios.

Builds on [CAP-13: Sanctioned execution profile pinning](sanctioned-execution-profiles.md).

## Evidence

- [RunEvidenceSpec.hs](../../shikigami-core/test-postgres/Shikigami/RunEvidenceSpec.hs): Call/retry/child roll-up, compliance mutations, sealing preconditions, transactional rollback, and query/rebuild fencing.
- [AttestationContractsSpec.hs](../../shikigami-core/test/Shikigami/AttestationContractsSpec.hs): Evidence-strength vocabulary and canonical payload bytes/digests.
- [Envelope.hs](../../shikigami-core/src/Shikigami/Attestation/Envelope.hs): Unsigned envelope contract and the explicit absence of implemented signing.

## Limits

Signing and a served attestation read API are not implemented; the envelope explicitly permits absent signature and key ID. This record claims the collector, evaluator, and store surfaces, not automatic signed evidence for every ordinary run. Rich payloads are LiveOnly: catalog rebuild preserves existing data and cannot reconstruct missing evidence from lifecycle events alone.

The available implementation is unreleased. No Shikigami release tags or published releases were present when this catalog was authored; the Cabal package version alone does not establish a released compatibility promise.
