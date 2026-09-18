---
id: 70
slug: apply-haskell-service-api-and-cli-patterns-with-wire-compatibility
title: "Apply Haskell service API and CLI patterns with wire compatibility"
kind: exec-plan
created_at: 2026-09-18T16:22:03Z
intention: intention_01m2trbg5ze1dt6dfz50mxg4bq
master_plan: "docs/masterplans/12-adopt-keiro-0-17-and-applicable-runtime-haskell-and-postgresql-patterns.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-18T16:22:03Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-18T17:23:14Z
      mode: "implement"
      note: "Started the independent Haskell, API, CLI, and configuration adoption stream"
---

# Apply Haskell service API and CLI patterns with wire compatibility

This ExecPlan is a living document governed by agents/skills/exec-plan/PLANS.md. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Update durable decisions in docs/adr/ when implementation changes them.


## Purpose / Big Picture


Bring applicable Haskell, HTTP API, command-line, configuration and deployment patterns into Shikigami's real user-facing behavior. Users should receive consistent errors and generated API documentation, useful offline CLI help/version/config checks, and safe structured logs. Hand-owned Haskell should follow current record and module conventions without changing durable JSON accidentally.


## Progress


- [x] (2026-09-18T18:03:00Z) Milestone 1: Audited and corrected hand-owned Haskell conventions.
- [x] (2026-09-18T18:03:00Z) Milestone 2: Closed the applicable HTTP and observability gaps.
- [x] (2026-09-18T18:03:00Z) Milestone 3: Made CLI and configuration behavior consistent.


## Surprises & Discoveries


2026-09-18: Strictness annotations are illegal on `newtype` payload fields under
GHC 9.12; those payloads are already represented by their single field. The
only lazy data-record field was corrected without changing a codec.

2026-09-18: PostgreSQL 18.6's `libpq.pc` now names `libcurl` in
`Requires.private`. Adding `curl.dev` to the development shell restored clean
package configuration; Hurl was added beside it for the black-box suite.

2026-09-18: The public API currently has only the two health GET routes. There
is no body, capture, query, authentication, collection, or alternate-media
surface on which to apply the corresponding problem and pagination patterns.

2026-09-18: The pre-existing `packages.default` calls `callCabal2nix` on the
multi-package repository root, which has no root Cabal file, so `nix build
.#default` stops before Haskell compilation. The revision fallback was instead
proved by compiling the actual version module from a Git-free indexed source
snapshot with an injected `GIT_HASH`; it reported `shikigami v0.1.0.0
(abcdef1)`. Repairing the repository's complete Nix package graph is separate
from this presentation-pattern stream.


## Decision Log


2026-09-18: This work may begin against the existing cohort while release compatibility is unresolved. Preserve established wire formats and generated code ownership. Apply conventions to real surfaces; do not invent clipboard, interactive selectors, pagination or provider-specific subprocess features merely to exercise a pattern.

2026-09-18: Share version rendering in `Shikigami.App.Version` across the
core-based operational executables. Keep the migration CLI's ADR 0032 boundary
and the lightweight client package independent rather than adding a core
dependency only for presentation.

2026-09-18: Use optparse-applicative's built-in Bash, Zsh, and Fish script
generators. They are already available on every parser run through
`execParser`, so a second completion-command architecture would duplicate the
parser authority.

2026-09-18: No new ADR is needed. The implementation preserves the existing
wire, configuration, migration, and package-boundary decisions.


## Outcomes & Retrospective


All 35 EP-5 rows in the adoption matrix now have a concrete disposition and
evidence. Hand-owned records use local generic-label instances and lens updates;
wire and workflow encodings remain unchanged. Request logging consumes
`Servant.Health.Paths.healthRawPaths`, RFC 9457 terminology is current, and the
new Hurl runner proves health plus 404/405 problem behavior against a disposable
database and the real server.

Operational core-based CLIs now expose shared offline version output with a
Git SHA, and Bash, Zsh, and Fish completion generation was exercised without
configuration or resource acquisition. The six package test suites, generated
OpenAPI drift check, live Hurl suite, and Keiro compatibility gate passed. The
consolidated review is `docs/evidence/keiro-0.17/ep5-haskell-api-cli.md`.


## Context and Orientation


There is no hard child prerequisite. All seven packages already declare GHC2024, DeriveAnyClass, DuplicateRecordFields, NoFieldSelectors, OverloadedLabels and OverloadedRecordDot. shikigami-core/src/Shikigami/Prelude.hs re-exports package-qualified lens functions and shared Aeson options without importing the generic-lens orphan. Preserve that separation so Keiki labels remain usable.

The current record standard is mori://shinzui/haskell-jitsurei/docs/core-record-patterns, resolved to patterns/core/record-patterns.md in mori://shinzui/haskell-jitsurei. AGENTS.md's older core/record-patterns.md path is absent. Its rules include concise strict fields, explicit deriving strategies, entity ID first in commands/events, local generic-lens instance imports, and lenses for updates. Generated record-dot access is explicitly accepted by [ADR 0037](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md); do not invent selector aliases or hand-edit generated modules.

shikigami-api/src/Shikigami/Api.hs owns Servant routes; Api/Problem.hs owns the six-field problem body; Api/OpenApi.hs derives docs/api/openapi.json from those routes. The code's RFC 7807 wording is stale terminology, not itself an incompatible wire format: the RFC 9457 pattern explicitly preserves that shape. Existing openapi-hs/servant-openapi-hs dependencies already use the fleet package names. shikigami-server/src/Shikigami/Server/App.hs, RequestLog.hs and Telemetry.hs compose serving middleware. Existing ProblemSpec, RequestLogSpec, TelemetrySpec and the API OpenApiSpec provide behavior tests.

shikigami-core/src/Shikigami/App/Role.hs and App/Config/Load.hs resolve configuration before acquiring resources. Server.Command, Workers.Command and Agent.Command own CLI surfaces. Health.Handler and Health.Worker separate readiness from loop liveness. flake.module.nix and process-compose.yaml own local build/runtime assembly. Inspect any actual Kubernetes assets before applying deployment-specific patterns.

Relevant local context includes [ADR 0037](../adr/0037-adopt-the-released-keiro-contracts-before-v1.md), [ADR 0038](../adr/0038-runtime-startup-and-maintenance-share-validated-owners.md), and [ADR 0001](../adr/0001-declare-only-what-the-runtime-executes.md). Read docs/adr/0020-readiness-covers-only-what-restarting-can-fix.md and docs/adr/0032-the-migration-cli-keeps-a-dedicated-configuration-boundary.md before changing probes or migration CLI configuration. The normative ownership split is mori://shinzui/keiro-runtime-patterns/okf/adrs/concepts/ADR-6.


## Plan of Work


### Milestone 1 — Audit and correct hand-owned Haskell conventions

Enumerate all current Haskell corpus documents through Mori and its index; read relevant documents before edits. In docs/architecture/keiro-0.17-pattern-adoption.md classify core, API, CLI, agent-tooling and governance guidance individually. If the release plan has not yet created the matrix, create only this plan's rows with the shared columns: canonical URI, inspected revision/date, applicability, current evidence, gap, owner, disposition and acceptance evidence; the release owner merges the full inventory later.

Check every library/executable/test component imports its baseline stanza, and audit strict fields, field prefixes, deriving strategies, postpositive imports, lens updates, multiline SQL and prelude/orphan placement in hand-owned modules. Fix demonstrated violations in coherent groups. Freeze serialized field names and sum encodings before record renames; use explicit codecs or field modifiers to preserve them. A source-only cleanup must not alter workflow step output or event encodings. Generated files remain scaffolder-owned. Route nominal adapter findings to docs/plans/67-adopt-language-6-and-executable-nominal-domain-contracts.md.

Acceptance is compilation and existing wire/property tests after each group, with no accidental serialization changes and documented reasons for intentional exceptions such as problemType mapping the reserved word type.

### Milestone 2 — Close real HTTP and observability gaps

Review all API patterns: Servant route/status types, RFC 9457 problems, type-derived OpenAPI, tracing, request logging, health, Hurl integration tests and pagination where collections exist. Exercise handler errors and framework errors before handlers: malformed body, invalid capture/query, 404, 405 and unsupported media. Ensure problem content type and status match, sensitive details are absent, and OpenAPI represents the actual public path/status/media set with stable operation IDs. Preserve any required Allow or authentication headers. Prefer compatible changes to existing APIs; typed MultiVerb guidance for new APIs does not require a gratuitous rewrite of working throw-based routes.

Verify one bounded JSON access log per request, no raw query/body/credentials, and trace IDs from the active server span. Test recovery behavior of readiness and independent loop liveness. Add black-box HTTP fixtures under tests/hurl/ with a local stub-only server and disposable database where needed; register a reproducible local command rather than requiring external services or model credentials. If collection routes need the pagination standard, implement it with a deliberate wire compatibility decision and tests; do not classify it inapplicable merely because existing pagination differs.

Regenerate the checked-in OpenAPI artifact through shikigami-openapi and keep the deterministic drift check. Acceptance is request/response and log evidence, not a marker saying the pattern was read.

### Milestone 3 — Make CLI/configuration behavior consistent

Read the CLI and runtime configuration standards and inspect every role from the existing role registries. Ensure --help and shell-completion generation work without database/provider access, invalid options fail clearly, and --check-config resolves and validates settings before resource acquisition with secrets redacted. Adopt version-with-Git-SHA output for executable surfaces that lack it, using a shared Shikigami.App.Version module and build-time revision fallback for Nix builds. Verify dependencies through Mori/Hackage before selecting any new package.

Apply help width/option grouping and stdin conventions where relevant to actual commands. Classify interactive fzf/clipboard, aliases, help-topic registries and provider-specific agent subprocess patterns by actual use; no matching surface means a recorded exclusion rather than a new product feature. Preserve Settei as the service configuration owner and the dedicated migration configuration boundary. Audit process-compose and any deployed manifests for probes, shutdown and secret injection; do not create Kubernetes infrastructure absent a deployment requirement.

Add tests in the existing agent/server/worker command suites. Consolidate completed pattern evidence and update durable ADRs if configuration or public contract policy changes.


## Concrete Steps


Run from /Users/shinzui/Keikaku/bokuno/shikigami:

```bash
mori registry docs shinzui/haskell-jitsurei
mori registry docs shinzui/keiro-runtime-patterns
cabal test shikigami-core-test shikigami-api-test shikigami-client-test shikigami-agent-test shikigami-server-test
cabal run shikigami-openapi
git diff -- docs/api/openapi.json
cabal run shikigami -- --help
cabal run shikigami-worker -- --help
cabal run shikigami-run-behavior -- --help
cabal run shikigami-migrate -- --help
```

After intentional generated artifact changes are committed, require git diff --exit-code docs/api/openapi.json after regeneration. Add tests/hurl/run.sh as the lifecycle owner for the local fixture; its documented invocation is:

```bash
bash tests/hurl/run.sh
```

That script must start only isolated/stub resources, wait for readiness, run hurl --test against the fixtures, and clean up its own processes on failure.


## Validation and Acceptance


Every Haskell corpus document and runtime config/deployment pattern has an applicability decision and evidence. Actual applicable gaps are fixed. Existing successful wire fixtures remain identical unless an explicitly documented public migration was necessary. Framework and handler failures use the intended problem contract without secrets; OpenAPI matches served behavior. Help/version/completion run offline, and config checks do not open resources. Probe tests distinguish restart-fixable failures from ordinary dependency unavailability. Hurl runs locally without live credentials. Source-only style changes use existing meaningful tests rather than tests that merely mirror formatting.


## Idempotence and Recovery


Work in small reversible source groups, preserving dirty user changes. Do not run a broad formatter over scaffolder-owned modules. Regenerating OpenAPI is deterministic; review intentional contract diffs before accepting them. Revert a codec-affecting cleanup before deployment if compatibility fixtures fail. Any real workflow-body change must follow docs/workflow-versioning.md; a refactor is not an exemption from stored-result compatibility. Fixtures clean up only resources they created.


## Interfaces and Dependencies


No hard dependency. Soft integration with docs/plans/66-resolve-and-adopt-the-released-keiro-0-17-dependency-cohort.md for shared Cabal bounds and with docs/plans/67-adopt-language-6-and-executable-nominal-domain-contracts.md for nominal adapters. This plan owns Haskell conventions, API/CLI presentation, configuration and deployment rows; it must not independently change queue semantics, SQL migration history or generated contract authority. Use mori://shinzui/haskell-jitsurei/docs/core-standards, mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details, mori://shinzui/haskell-jitsurei/docs/api-openapi-from-types and mori://shinzui/haskell-jitsurei/docs/cli-version-git-sha as canonical entry points. Version/probe/telemetry ownership should be shared across executable roles rather than copied.
