# Bundle Update Log

## 2026-10-10

* **Adoption**: Bootstrap OKF 0.2 with the shared
  `mori://shinzui/okf-profiles/profiles/capabilities` profile from the upstream
  `v0.20.0` tag and a frozen Dhall integrity hash.
* **Addition**: CAP-1 through CAP-18 document typed declarations, durable intake,
  program/Skill execution, agent Flows, memory, principal continuity, exact-action
  authorization, routing/delegation, sink delivery, human approval, conversations,
  tool overlays, profile pinning, run evidence, advisory practice review, HTTP
  health, worker operations, and foreground launches. Evidence paths were opened
  and checked; linked runtime tests were not rerun for this documentation change.
* **Integration**: Register the bundle in `mori.dhall`, link it from the repository
  README, and add index/profile/log/evidence/dependency validation commands.
* **Scope**: Records are experimental and unreleased because Shikigami has no
  release tags or published releases. Unsupported deterministic rules, background
  CLI response providers, shared recall, public run/attestation HTTP endpoints,
  signing, mutable workspaces, cross-runtime A2A, and complete production review
  evidence are excluded from provision claims. Independent review is pending;
  no review or verification provenance is asserted.
* **Coverage audit**: Census all seven Cabal packages, their 163 exposed modules
  (including the public test-support sublibrary), twelve executables, and eleven
  repository-owned administrative command families. Add CAP-19 for migration and
  database bootstrap and CAP-20 for local integration fixtures. Expand existing
  records for direct enqueue, client/worker health, Skill validation, joined run
  inspection, configuration diagnostics, and request logs. Correct CAP-14's
  consumer interface to the public evidence-store query instead of its private
  implementation module. Record the mappings and exclusions in
  `../capabilities-coverage.md`.
