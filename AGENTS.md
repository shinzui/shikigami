## Haskell Record Fields

Follow `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md` for Haskell records. In particular, do not prefix record fields with the type, constructor, or module name; rely on `DuplicateRecordFields` and use direct field names such as `status`, `runId`, or `baseUrl`.

## Durable Workflow Changes

Shikigami runs agent runs and Danwa conversations as durable keiro workflows whose
journals outlive the code that wrote them. **Any change to a workflow body — under
`shikigami-core/src/Shikigami/Agent/` or `shikigami-core/src/Shikigami/Flow/` — must
follow [docs/workflow-versioning.md](docs/workflow-versioning.md).** It states which
step-shape changes are deploy-safe, when `patch` and `continueAsNew` are required, and
how a patch id is declared in `domain/` and gated by `just keiro-gate`.
