# Adaptive delivery host qualification

Qualified on 2026-11-04 UTC, macOS arm64 with the existing GHC 9.12.4 development
environment and disposable PostgreSQL databases. The implementation baseline is
`05e2a3d94deeb0dd1d92c16e8403707dc9bb7c99`. Native controller source is checkpoint
`a497b440`; the fixture/driver begins at `f468b6b9`, with bounded observation
corrections in `8ee142f2` and the subsequent Git artifact retention change.

[Plan 86](../../plans/86-qualify-integrated-adaptive-autonomous-delivery.md)
remains In Progress. These are host component and fixture-mechanics results.
They do not establish the new coupled Linux runtime, the complete fault matrix,
a live model trial or UC-1 delivery. No live model credentials were used.

| Check | Result |
| --- | --- |
| `cabal build all` through Nix | Passed, including the optional native fixture executable |
| Core unit suite | 706 passed |
| Core PostgreSQL suite | 572 passed |
| Worker suite | 291 passed |
| Server suite | 105 passed |
| Existing `AdaptiveWorkflow` PostgreSQL group | Five passed; also included in the full PostgreSQL total |
| Python qualification tools | 36 passed, including fifteen new adaptive-delivery controls |
| Migration schema isolation | Passed |
| Haskell conventions and checker controls | Passed, thirteen checker controls |
| Changed shell syntax | Passed |

The four requested Haskell suites total 1,674 cases. They ran sequentially with
`TASTY_NUM_THREADS=2`. This slice changes no production workflow body, domain
declaration or migration, so no new workflow evolution gate is claimed.

The new tests prove deterministic seed objects, passing local checks with a
failing combined journey, the corrected journey, private evidence handling,
configuration/limit refusal, unavailable-live blocking, bounded output and
process-group deadlines. Tampered native manifests refuse stale bases,
duplicate operations, failed checks and unknown root work. A separate Git
restoration case exports an actual local bundle, removes access to the source
path, fetches it into a fresh repository and compares exact commit/tree IDs and
file bytes. This establishes the artifact-retention mechanism, not native
adaptive repository execution.

Run from the repository root:

```bash
nix develop --no-write-lock-file -c cabal build all
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-server-test --test-show-details=direct
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-show-details=direct
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-workers-test --test-show-details=direct
python3 -m unittest discover -s tools/qualification -p 'test_*.py' -v
nix develop --no-write-lock-file -c just migration-schema-isolation
nix develop --no-write-lock-file -c just haskell-conventions
bash -n tests/workspace/run-apple.sh tests/workspace/run-linux.sh
```

FRIC-54 in `docs/friction-log/` records the full dependency rebuild incurred by
fixture-only native Nix changes. A successful build alone cannot supply runtime
evidence. Keep the live gate and complete coupled fault matrix open regardless
of these host results.

On resumption later on 2026-11-04 UTC, the Python qualification suite passes
40 cases. Native evidence parsing now restores all six bundles into fresh bare
repositories, verifies exact HEADs, direct parents and Git object integrity,
recomputes both combined trees from their worker pairs, and runs the journey on
the returned combined blobs. Tests use real Git bundles; matching hashes of
non-Git bytes, a substituted tree, omission of a worker change, and an obsolete
consumer schema each refuse acceptance. This strengthens the host verification
mechanism and does not add native runtime or live-trial evidence.
