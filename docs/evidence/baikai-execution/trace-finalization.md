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
structured-content cases. Remaining serial application/database checks and
immutable builds are in progress. No Linux runtime, live provider, authenticated batch
reporter or final immutable role acceptance is claimed by this checkpoint.
