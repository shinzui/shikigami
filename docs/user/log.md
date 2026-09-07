# Bundle Update Log

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
