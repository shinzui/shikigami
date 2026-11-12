# Baikai 0.10.1 behavior consumer qualification

The candidate uses index `2026-11-12T17:25:33Z`, core Baikai 0.10.1.0,
Effectful adapter 0.4.0.5 and Shikumi 0.5.1.0. Release identity and the exact
frozen export are recorded in [the dependency cohort](../../dependency-cohort.md).
The isolated all-component solve succeeds without adding bounds overrides.

`BehaviorToolSpec` calls the application `completeBehaviorRequest` boundary
through a private public-provider registry. The preterminal cancellation case
synchronizes on provider readiness, throws `ThreadKilled`, joins the caller and
immediately inspects the healthy sink. It requires one correlated start,
abort evidence and failed terminal, in that order, with the original exception.
The terminal-drain case blocks the sink after recording a successful terminal,
cancels the caller and requires bounded return without replacing or duplicating
that terminal. Fixture cleanup releases the blocked sink. A separate failed-sink
case synchronizes on sink failure and requires the original cancellation within
the same bounded join window.

`BaikaiStructuredContentSpec` exercises the same application boundary with mixed
text/data output, retaining the probability maps, confidence, method and absent
call evidence in the trace. Its cache fixture starts with real evidence data,
retains it through Baikai full-response serialization, then requires both
Shikumi cache serialization and a memory-cache hit to strip it
while preserving answer content and making only one underlying call. Assistant
replay preserves the same content.

`TypeSafeDecisionSpec` adds complete/stream application cases for HTTP 400,
missing answers, invalid predicate probability and unknown choice labels. These
require bounded failed actual attempts and no retained successful answer. The
public Shikumi HTTP 400 mapping is `OutputDecodeFailure`.

The immutable package now installs the supplied-ticket manifest at
`share/shikigami/agents/proof/shikumi-judgment-example.dhall`; its relative schema
import resolves to `share/shikigami/schema/Agent.dhall`.

The first test configuration stopped because the running Cabal process held the
pre-edit dependency plan when `async` was added to the test descriptor. A fresh
solve rebuilt the tests and all 20 behavior-tool checks passed. The first full
core run had three assertion failures: both HTTP 400 cases expected
`ProviderFailure`, and the cache test expected serialized evidence retention.
Source inspection confirmed the actual public contracts above; assertions were
corrected and the serial run repeated. The initial immutable build was stopped
when source review found the proof manifest excluded by `runtimeSource`; the
corrected filter is included in the restarted build.

All 801 core checks pass, including 20 behavior-tool, 23 TypeSafe and nine
structured-content cases. All remaining serial application/database checks and the five immutable role
builds passed; exact counts and package outputs are in [the machine-readable
checkpoint](trace-finalization.json). No Linux runtime, live provider, authenticated batch
reporter or final immutable role acceptance is claimed by this checkpoint.

The serial run passed core 801 and workers 353, then stopped at migration
smoke because migration 0049's mandate objects were absent from the reviewed
schema snapshot. Native regeneration added exactly 34 entries matching that
SQL. The regeneration invocation wrote the snapshot but failed against the
previously embedded verifier; a rebuild then passed all 11 smoke checks.
FRIC-68 in `docs/friction-log/` is resolved. The package build containing the
stale snapshot was stopped; final package qualification remains outstanding.

At source checkpoint `ba63a3db`, native qualification passes core 801, workers
353, core PostgreSQL 681, agent 37, server 114 and migration smoke 11 checks
(1,997 total). The committed workflow gate passes 210 conformance assertions,
no generated drift and a replay-neutral verdict. It uses the same isolated
project via a temporary Cabal wrapper; no ignored project override is changed.
Haskell conventions, migration schema isolation and whitespace checks pass.
The native TypeSafe queue/restart fixtures are included in the PostgreSQL run.

All five native immutable roles built successfully at `ba63a3db`. Ten
outside-checkout checks passed with provider API keys absent: each role's help,
interactive configuration, both unattended help levels, installed judgment
manifest validation and lifecycle rendering. The installed manifest resolves its
schema import without checkout assets. This proves installed loading and command
composition; installed judgment enqueue/worker execution remains unqualified.
No Linux runtime, live provider or authenticated batch reporter trial was run.
The full off/cache wire, structured-error and judgment authority/budget matrices
still keep Plan 80 open.
