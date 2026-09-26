# Bundle Update Log

## 2026-09-26

* **Addition**: IR-13 proposes optional major-task tracking without Rei and records the current
  memory, Flow, overlay, replay, and authorization boundaries for further design.
* **Addition**: IR-12 requests replay-safe Shikumi decision steps within durable Flows and
  governed model selection per step, with pinned policy, replay, and mixed-model evidence.

## 2026-09-21

* **Audit**: Reconciled all eleven lifecycle values against the current ExecPlans,
  MasterPlans, Git history, and repository tree. IR-1, IR-3, and IR-9 are complete; IR-4
  and IR-7 are in progress; IR-2, IR-5, IR-6, IR-8, IR-10, and IR-11 remain proposed.
* **Review**: Added model review provenance for the lifecycle and planning-coverage audit to
  every request. The review covers catalog metadata, not a fresh review of each design.
* **Update**: Repinned the improvement-request profile from v0.10.0 to the authoritative
  okf-profiles v0.18.0 release.

## 2026-09-20

* **Addition**: IR-11 requests governed isolated mutable repository workspaces and bounded coding
  tools for durable upgrade agents.
* **Addition**: IR-10 requests a public terminal agent-run status endpoint so Mori can correlate
  an accepted run with its durable succeeded or failed outcome.

## 2026-08-17

* **Migration**: Move the bundle to OKF v0.2, adding `generated` provenance to every request
  and declaring `okf_version` in the bundle root.
* **Update**: Repin the profile descriptor to `okf-profiles` v0.10.0.

## 2026-08-10

* **Addition**: IR-9 requests Meibo-principal keying for durable agent memory, grants,
  lineage, and outbound authorship, including migration from name-keyed history.

## 2026-08-07

* **Addition**: IR-8 requests an addressed agent-run vertical on the public HTTP API so
  `mori://shinzui/mori` can fire agents from matched repository events across the service
  boundary, instead of writing into the shared run-job queue.

## 2026-08-02

* **Addition**: IR-7 requests sanctioned execution profiles, complete call roll-ups, artifact
  binding, and signed run attestations for
  `mori://shinzui/kikan/okf/use-cases/concepts/UC-8`.

## 2026-07-30

* **Migrate**: Assign stable handles to Shikigami improvement requests.
* **Move**: Accept cross-cluster diagnostics and governed-evolution requests from Kikan.
* **Link**: Relate the A2A owner request to Kikan's accepted portfolio request.
