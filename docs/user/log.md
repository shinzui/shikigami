# Bundle Update Log

## 2026-11-21

- Updated the first-run, declaration and CLI examples for stock and Kikan execution. Documented manual triggers, composition defaults, the six behaviors, playbook recovery and the roles that own the organizational packs.
- Checked a scaffolded Skill through first confirmation, report delivery and a second unattended run against disposable PostgreSQL. The typed-decision example completed with the stub provider, and the stock HTTP heartbeat progressed from acceptance to success. Validated the campaign bundle and the stock/Kikan heartbeat output boundary.

## 2026-11-16
* **Addition**: DOC-13 documents `shikigami record check` and the `run.admitted`, `run.finished` and `output.delivered` entries; DOC-23 explains the `kawa.digest` output, the worker's `outputs.default` and the portability check (EP-8 M3).

## 2026-11-15
* **Update**: DOC-25 covers `Reflect` steps, learnings, suggestion branches, `FromStep` fan-out and attached skills; DOC-6 points to playbooks (EP-4 M3, M4).
* **Addition**: DOC-25 explains playbooks: bundles, `playbook validate`, the `Playbook` behavior, approvals and `--resume` (EP-4).
* **Addition**: DOC-22 explains declared tools as durable steps (`run-declared-tool`, `--resume`, uncertain outcomes) (EP-3 M4).
* **Addition**: DOC-24 is the routine-agent guide: `new`, `run`, scheduling with `up`, `runs` and `doctor` (EP-9 M3).
* **Addition**: DOC-13 documents `shikigami-local runs` and `shikigami-local doctor` (EP-9 M2).
* **Addition**: DOC-13 documents `shikigami-local new` and `shikigami-local run` for routine agents (EP-9 M1).
* **Addition**: DOC-23 explains outputs, the composition default (a local report), `Trigger.Manual` as the default, `approval.require_outputs` and the local approval inbox (EP-8 M2). DOC-13 lists `shikigami-local approvals pending|resolve`.
* **Addition**: DOC-22 explains declared tools for coding agents: the gate hook, strict MCP configuration, the Codex rule and the Baikai ceiling setting (EP-3 M3).
* **Addition**: DOC-22 explains MCP server tools: the operator binding, `shikigami-local mcp` discovery and the schema check at acquisition (EP-3 M2). DOC-13 lists `shikigami-local mcp`.
* **Addition**: DOC-22 explains declared CLI tools: the `tools` field, the one-time grant, `shikigami-local tools`, the optional ceiling file and the `tool.called` record (EP-3 M1). DOC-13 lists `shikigami-local tools`.
* **Addition**: DOC-21 explains queued coding agents in a `local-operator` worker; DOC-13 documents `shikigami enqueue-run --workspace` (EP-2 M2b).
* **Addition**: DOC-13 documents `shikigami-agent-run --resume`; DOC-5 says how an interrupted coding-agent step is continued (EP-2 M2).
* **Addition**: DOC-5 documents the `CodingAgent` behavior arm: Claude Code or Codex as a durable step that commits on the run branch, its outcomes, attached skills and the local-operator tier requirement (MasterPlan 22, EP-2 M1).
* **Addition**: DOC-21 covers editing, approved command rules, commits on a run branch and in-place repositories (EP-1 M2).
* **Addition**: DOC-21 explains the local-operator trust tier: one confirmation per declaration, the explicit approvals file, `shikigami-local` and the action record (MasterPlan 22, EP-1 M1).
* **Correction**: DOC-13 (`cli.md`) documents `shikigami record list`, the record written by both one-off commands, `shikigami-agent-run --payload/--no-confirm` and `shikigami-local`, and replaces the deny-all limitation with the local-operator path.

## 2026-11-06
* **Correction**: Refresh all three HTML artifacts and their supporting Markdown roadmap through plan 124 and IR-21, including completed workspace/objective providers, native adaptive recovery evidence, watchdog delivery, unrequested-work admission, and the planned machine-daemon lane.
* **Correction**: DOC-1/13 remove obsolete absent-provider wording; DOC-1 links DOC-18–20. DOC-4/5/6 link delivered schedule and Flow paths; DOC-13 covers objective/tracker, proposal and watchdog commands; DOC-19 distinguishes passing native qualification from the remaining actual-model trial; DOC-20 expands scoped inspection and independent overdue monitoring.
* **Validation scope**: Compare guides with current command parsers, registered Flows, owner plans and retained acceptance reports. Documentation checks do not rerun runtime qualification or close the live-model and recurring-mandate gates.
* **Checks**: Regenerated user index; strict profile validation passes for all 20 pages. Checked 625 local links/anchors across user guides, HTML artifacts and the Markdown roadmap, HTML structure and diagram labels, and portfolio counts/request lifecycle rows against repository records.
* **Addition**: DOC-20 explains watchdog notices, trusted recipients, bounded evidence and operator inspection.

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
