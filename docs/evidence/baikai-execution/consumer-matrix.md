# Baikai application consumer and installed judgment qualification

Runtime source `847d5de2292d0de2e9d4145951226a2989f9738d` adds the finite-cost
judgment refusal. Subsequent boundary commits `47c45825` and `0fdd0797` change
tests/documentation only. The exact immutable paths and counts are retained in
[consumer-matrix.json](consumer-matrix.json). The frozen cohort/index is unchanged.

Native qualification passes core 866, PostgreSQL 683, workers 353, server 114,
agent 37 and migration smoke 11 checks: 2,064 total. Database acceptance uses one
Cabal invocation with `-j1` and `--num-threads=1`. The committed workflow gate
passes 210 assertions with a replay-neutral verdict and no generated drift.
Haskell conventions and their 13 tests, migration schema isolation
and whitespace checks pass. Existing historical codecs remain unchanged.

The generative fixture resolves ordinary application configuration and uses the
common builder plus public HTTP adapters. Twelve successful wire combinations
cover default/off reasoning and absent/Short/Long retention where supported.
Three offline refusal cases name the unsupported setting and leave the HTTP
counter at zero. Anthropic marks the shared system text block; modern OpenAI
bindings mark the shared prefix. Two requests keep the same prefix and different
user questions. Evidence retains the requested/translated reasoning separately
from absent provider observations; no cache hit is inferred. Governed Anthropic
aliases independently prove default/off wire and retained evidence, pinned
retention and immutable actual tuples.

The 64 TypeSafe complete/stream cases cover exact questions and state, raw versus
weighted derived answers, malformed probability maps/legends, HTTP 400/401/403/
422 and transient 429/500 handling, timeout/cancellation, failed terminal
acknowledgement, truncated events, immutable binding/profile refusals and finite
token/cost policies. Actual catalog admission separately proves the installed
example's alias declaration and judgment-only slot intersection. The runtime
also refuses a generative program carrying a prepared judgment binding, before
attempt admission or HTTP. Unknown judgment prices cannot satisfy a finite
spending policy as zero; ADR 0041 records that constraint.

Structured optional-field absence survives response serialization, protected
snapshots and replay. Existing evidence-bearing cache proofs strip historical
call evidence while retaining answer content. The accepted-executor fixture
records mixed text/data, retires its provider, repeats the accepted operation
and reads the identical protected structured outcome with one total provider
call. The real behavior evidence collector retains one correlated abort before
the original cancellation returns. Existing stalled/failed-sink cases preserve
bounded cleanup and the committed terminal.

Both released CLI adapters pass Darwin complete, active synthetic-stream and
version-probe cancellation with resistant inherited children, repeated
cancellation, an unrelated live sentinel and Codex schema-file cleanup. The
original asynchronous exception propagates. These results qualify inherited
process groups; deadlines, retained output, detached descendants and native-tool
confinement remain separate requirements. No CLI response promotion is claimed.

All five native immutable roles build at runtime source `847d5de2`. Ten installed
help/configuration/launch/manifest checks pass outside the checkout. The explicit
PostgreSQL test mode then runs the actual packaged operator and worker with the
installed proof manifest, a temporary HOME, a minimal environment and a
disposable database/loopback server. Configuration makes zero requests. Enqueue
and worker execution retain raw category `technical` alongside derived category
`billing`, urgency probability 0.83 and expected severity 1.5. A worker restart
and duplicate enqueue preserve the outcome with one total HTTP request. The
separate native fault test covers restart between decision commitment and
top-level completion; the installed duplicate check does not replace it.

The first installed probe failed during restart because `createProcess` closed
its reused log handle. The corrected probe uses public `createProcess_` from
`mori://haskell/process/packages/process` to keep
that caller-owned handle open; a fresh database/server retry passed. This was a
qualification-driver defect and required no runtime/package change. An earlier
dirty runtime build and overlapping preliminary worker test were stopped; only
the committed runtime outputs and final serial invocation qualify this checkpoint.

Reproduce the serial suites using the isolated project from Plan 80. Build the
PostgreSQL test executable and use its explicit installed mode as described in
[the qualification tooling guide](../../../tools/qualification/README.md).
The driver requires absolute packaged paths and never substitutes checkout
commands. Native crash/restart and structured fixtures remain in the ordinary
PostgreSQL suite.

No remote provider, live cache, native Linux, authenticated batch reporter or
Plan 79 service/trust/delivery acceptance is claimed. M7/M8 are qualified. M1's
remaining batch bounds/confinement contract and Linux gate still block CLI
configuration/dispatch and the authenticated trial; future CLI changes require
final candidate regression and rebuilding under M5.
