# Plan 65 acceptance evidence

The [ExecPlan](../../plans/65-migrate-shikigami-to-the-keiro-0-15-cohort-and-the-idiomatic-v2-record-model.md)
records release verification, the four unused-state facts and qualification commands.

- `workflow-reset-diff.json` and its replay-impact companion record the deliberate
  removal of ten pre-release workflow patches, committed in `f1118af`.
- `queue-identity-reset-diff.json` and its replay-impact companion record the
  generated queue adoption and evidence identity reset, committed in `f43b0ca`.
- `behavior-conformance.json` is the executed domain report: 56 filled obligations,
  50 verified, six unverified with passing witnesses, and no failed or missing
  obligations. Unverified proof coverage is not relabeled as verified.
- `final-gate-diff.json` and its replay-impact companion record the passing
  ordinary gate against `8b0a98a`: no findings and replay-neutral behavior.
- `final-suites.json` records all 14 passing serial suites: 847 counted checks
  plus two custom dependency drivers.
- `bounded-resume-preview.txt` records the built worker CLI reporting its finite
  budget without acquiring a database or advancing workflows.
- `scenario-acceptance.txt` records real isolated PostgreSQL scenarios for generated
  queue ingestion, recreated runtime/approval resumption, explicit caller-owned
  review evidence, generation-specific tokens and HTTP receipt-gap deduplication.
- `future-incompatible-diff.json` and its text explanation come from a disposable
  copied workspace with `ingest-job` renamed to `ingest-job-incompatible`. The
  unmodified differ exits 1 with one `WorkflowBodyChanged` finding. Its `HEAD`
  reference names the fixture's private baseline, not this repository's moving HEAD.

The accepted reset diagnostics are intentionally breaking. Later ordinary gates
against the new committed baseline do not erase or reclassify them. No shared or
developer database was reset for this work; database faults and migrations ran
only in disposable per-example clones.
