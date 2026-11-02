# No-Rei objective qualification

From the repository root:

```bash
nix develop --no-write-lock-file -c bash tests/objective-tracking/run.sh
```

The runner builds the real server, worker, migration and operator binaries plus
an optional fixture executable. Set `SHIKIGAMI_CABAL_PROJECT` to an existing local
cohort project if required by [dependency setup](../../docs/dependency-cohort.md).
It needs Cabal, PostgreSQL tools, curl and Python 3. It creates a private temporary
directory and Unix-socket-only PostgreSQL cluster, then removes its own resources
on exit. It uses no Rei endpoint, host credential or external messaging service.
Runtime subprocesses receive a cleared environment and disposable configuration.

The loopback model is a scripted Responses SSE transport. Real production parsing,
tool admission, C13 verification, execution owners, queue, workflow journals and
objective stores execute. The loopback authority issues short-lived exact-action
Biscuit proofs for the three fixture principals, with a fixed public fixture key;
these credentials must never be used for a deployment. The OAuth proxy uses
public fake credentials. The fixture producer enqueues conversation turns through
the production producer; reply delivery is denied independently by C11.

The serving scenario starts with no objectives. It holds the first objective
command's protected outcome insertion after the Goal commit, kills the owned
worker, then restarts both server and worker with creation permission removed.
The original accepted binding recovers the same origin, Goal and receipt and
settles the superseded command attempt using the factual immutable command receipt.
The runner compares frozen snapshot bytes without printing protected payloads.
A new associated run and an explicitly bound recorded conversation continue with
both learning recall paths disabled. No fabricated source proof or direct Goal
state update supplies these outcomes.

A separate authenticated API scenario creates two finite assignments and drives
two real workers. It reads their retained terminal outputs, verifies their
component values and commits a hash over the combined artifact. Worker success
leaves the Goal open. An absent integrated journey check refuses acceptance;
changing criteria makes the old proposal stale. An authorized completer's
explicit current attestations and exact proposal then permit one acceptance,
whose identical retry returns its receipt. These are human-verifiable criteria:
this fixture does not install or claim a general automatic verifier. The core
contract tests separately exercise trusted automatic-verifier result validation.

The transcript also reports refused unauthenticated/non-member access, denied
creation and an unrelated accessible Goal selector, plus stale public commands.
A subsequent real PostgreSQL provider suite qualifies checkpoint lost-ack recovery,
sibling ordering, instruction-only invalidation (including text reversal),
ownership continuity, cancellation/late facts, and the live unresolved-attempt
completion barrier. Its fence evidence is explicitly deterministic. The mutable
inspection loss case remains unresolved even after logical success, until the
original retained output arrives under the actual dispatch claim; then the same
acceptance key can succeed.

This does not qualify real repository fencing, Git publication/handoff, adaptive
or recurring orchestration, external Danwa delivery, or public model services.
Those remain separately owned gates. See [plan 102](../../docs/plans/102-qualify-no-rei-objective-continuity-and-close-ir-13.md)
and [operator guidance](../../docs/operations/objective-tracking.md).
