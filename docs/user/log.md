# Bundle Update Log

## 2026-11-05
* **Correction**: Plan 124: describe registered programs and typed decisions through the Shikigami-owned Shikumi execution adapter in DOC-1, DOC-5 and DOC-15.

## 2026-11-04
* **Addition**: Add the unrequested-work guide for what a person sees when an agent proposes work nobody asked for.
* **Correction**: Give the adaptive-delivery guide the frontmatter the profile requires, so the bundle validates.

## 2026-11-03
* **Correction**: Document configured objective-backed coordination and shared process-backed supervisor requirements for CoordinatingSkill; remove obsolete absent-provider wording after plan 84 consumer acceptance.

## 2026-11-02
* **Addition**: DOC-17 explains explicit tracker binding, bounded review, scoped pages and uncertainty recovery. DOC-1 links it; DOC-16 distinguishes passive references from optional synchronization.
* **Addition**: DOC-16 documents durable objectives, creation and continuation, exact retries and explicit integrated completion. DOC-1 links the guide.

## 2026-10-29
* **Correction**: Document `execution` and `harness` manifest fields, resource/execution/
worker command families, retained assignment model bindings and remaining real-provider
gates. Link current operation guides; preserve the separate client parser and authority
requirements. This is documentation validation, not live runtime qualification.

## 2026-10-25
* **Addition**: DOC-14 explains authenticated HTTP discovery, atomic idempotent run
acceptance, lifecycle polling, HTTP acceptance history, and DLQ evidence retention.
DOC-15 provides a two-model typed-decision smoke path with replay and evidence limits.
* **Correction**: Add `decisionModels` to declaration guidance, update all FlowDef
examples with slot/default-model fields, and document remote client commands,
wait exit codes, direct HTTP intake, and navigation to the new guides.
* **Validation scope**: Compare claims and examples with current schemas, parsers,
handlers, workflow code, and existing acceptance tests. Runtime suites were not
rerun for these documentation-only changes.
* **Checks**: Strict user-profile validation passes for all 15 pages. Local links
and anchors pass across the user, capability, and HTML artifact directories;
regenerated navigation includes both new guides.

## 2026-09-07
* **Bootstrap**: convert the 13 existing user-guide pages (DOC-1 through DOC-13)
to OKF 0.2 using the shared
[user-documentation profile](mori://shinzui/okf-profiles/profiles/user-documentation),
pinned to v0.14.0. Preserve existing page paths and instructional content,
classify pages by reader intent, and add stable handles and migration provenance.
* **Addition**: provide a generated index, Mori bundle registration, and
`just user-docs-index` / `just user-docs-validate` maintenance commands.
* **Correction**: audit current README and user guidance against declaration schemas,
command parsers, behavior dispatch, Flow capabilities, durable identity, and action
authorization. Correct setup order, CLI coverage, executable detector status,
ignored Skill metadata, one-off overlay restrictions, and living-loop prerequisites.
Keep historical design and planning claims distinct from current runtime support.
* **Validation**: strict OKF validation passes for all 13 user pages. Checked 156
local guide links and Markdown anchors, all 49 configuration keys and environment
bindings, the dependency dry run, heartbeat validation/run, and the stub Skill run.
Confirmed the documented unsupported detector and denied workspace outcomes using
the built binary; the revised Haskell Flow example type-checks against the current
library. Regenerated OpenAPI from the served contract with no artifact drift.
Live database, broker, and downstream delivery were not exercised in this audit.
