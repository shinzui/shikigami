# Native administrative inspection — plan 106 M1

The candidate mounts all four generated aggregate streams through the released public inspector API: ExecutionLifecycle, WorkerSessionLifecycle, ObjectiveLifecycle and RunEvidence. The descriptor census is checked against generated replay-audit targets, rather than a separate fixed count. No process-manager descriptor is fabricated: the application has durable workflows but no compiled reaction manager.

Display authority is an explicit object field allowlist. Execution exposes identity, revision and pending receipt count; worker sessions expose identity and revision; objectives expose identity and revision; evidence exposes its identity and run identity. Snapshot digests, binding digests, tool input, protected payloads and model history are excluded. Adding a persisted register cannot publish it implicitly.

## Native evidence

Run from the repository root:

```bash
nix develop --no-write-lock-file -c cabal test shikigami-server-test --test-options='--num-threads=1' -j2
```

```text
All 71 tests passed (4.32s)
1 of 1 test suites (1 of 1 test cases) passed.
```

The suite provisions disposable fresh databases through the source-owned migration fixture; no database case skips. Cabal supplies the actual built administrative executable as a build tool. The first representative ExecutionLifecycle CLI check passed before the catalog expanded. Final cases cover:

- Native type/list/show of an admitted execution and exact safe state JSON without either private fixture digest.
- Page size one, an opaque continuation, exclusive next page and typed refusal to reinterpret that cursor for WorkerSessionLifecycle.
- Typed `invalid_page_size` and malformed `invalid_cursor` outcomes through the native console runner.
- `Never`/no-codec configuration for every descriptor, `full_replay`/`no_state_codec` hydration and absent/unconfigured snapshot status for the actual instance.
- Corrupt native event history returns `AggregateHydrationFailed`; a missing instance returns `AggregateNotFound`. Neither renders a successful initial state or an empty page.
- The native CLI's bounded workflow inspection, pending timer page and projection status page, plus the actual empty shard inventory. Shard inventory is the released unpaginated operation; HTTP deadlines and encoded-byte limits remain M2 obligations.
- `--database-url` is a named Settei source, wins over an injected environment value, appears in provenance and remains redacted in diagnostics. The native public invocation receives the resolved value directly. No process environment write remains.
- Existing native replay-audit and projection catalog hooks remain mounted; resource-dependent workflow resume and timer execution hooks remain absent.

This milestone does not qualify an HTTP listener, WebSocket protocol, worker-local metrics, inspection load or Linux runtime. Those remain M2/M3 and final plan 95 work. The raw console remains a trusted local operator interface with upstream mutation previews and native exit codes; no successful exit is mislabeled as proof that a requested mutation changed state.

Public dependency sources: `mori://shinzui/keiro/packages/keiro`, `mori://shinzui/keiro/packages/keiro-ops` and `mori://shinzui/settei/packages/settei-optparse-applicative`.
