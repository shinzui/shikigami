# Heni pure-resource pilot — 2026-11-09

The released Heni 0.1.0.0 CLI catches all three selected implementation faults.
The unchanged source passes. Two deliberately unmet contracts verify that a
surviving edit and an unrelated compiler error do not count as detection.

| Case | Observed verdict | Evidence |
| --- | --- | --- |
| Finite capacity guard bypass | Caught | Representable excess assertion fails; the existing refusal-order assertion also fails. |
| Missing reserved billing dimensions accepted | Caught | Incomplete-settlement assertion fails. |
| Root revision guard bypass | Caught | Stale expected revision assertion fails. |
| Unchanged source | Caught / control passed | All 11 owning tests pass. |
| Harmless comment edit | Survived | All 11 tests still pass. |
| Missing identifier in revision guard | UnexpectedBuildFailure | Candidate compilation fails before tests. |

The positive campaign exits 0, with semantic detections **3/3** and one separate
passing control. The negative campaign deliberately exits 1, with no caught
cases. Both campaigns use the same captured source identity. This is a selected
three-fault score, not a measure of repository-wide mutation coverage.

The independent CLI was built from the released Hackage package with:

```bash
mkdir -p .dev/heni/bin
nix develop --no-write-lock-file -c cabal install --ignore-project heni-cli-0.1.0.0 --installdir=.dev/heni/bin --install-method=copy -j2
```

The final candidate was exercised from the repository root:

```bash
nix develop --no-write-lock-file -c just mutation-tests .dev/heni/bin/heni mutation-results/final-pilot
nix develop --no-write-lock-file -c cabal exec -- "$PWD/.dev/heni/bin/heni" run tests/mutation/heni.json --tag negative-control --output mutation-results/final-controls
nix develop --no-write-lock-file -c cabal test shikigami-core-test --test-show-details=direct
nix develop --no-write-lock-file -c just haskell-conventions
nix fmt -- tests/mutation/Build.hs tests/mutation/Main.hs shikigami-core/test/Shikigami/ExecutionResourcesSpec.hs
git diff --check
```

The regular core suite passes **789 tests**. Haskell conventions and their 13
existing checker tests pass. Formatting and whitespace checks pass. Production
resource source and dependency pins remain unchanged. Two boundary tests were
added to the owning Haskell suite for representable excess and stale revisions.

[Source identities](source.json) record the baseline commit, compiler, captured
file hashes, CLI binary hash and solved dependency-plan hash. The actual Heni
reports are preserved byte-for-byte in [pilot-report.json](pilot-report.json)
and [controls-report.json](controls-report.json). Their relative stdout/stderr
log names resolve to entries under the corresponding `pilot` or `controls` object
in [transcripts.json](transcripts.json). Empty streams are retained too.
For Heni's artifact verification, [logs.tar.gz](logs.tar.gz) preserves the original
flat log files. Restore them beside the reports in a fresh ignored directory:

```bash
mkdir -p mutation-results/published
tar -xzf docs/evidence/mutation/logs.tar.gz -C mutation-results/published
cp docs/evidence/mutation/pilot-report.json docs/evidence/mutation/controls-report.json mutation-results/published/
.dev/heni/bin/heni report mutation-results/published/pilot-report.json
.dev/heni/bin/heni report mutation-results/published/controls-report.json
```

Each baseline and candidate compiles the production resource module with its
owning test suite using fresh GHC outputs. Remaining imported modules come from
the already prepared host package databases. Build reuse is disabled. This
qualifies the focused compilation path on aarch64 macOS with GHC 9.12.4; it does
not independently qualify the host's dependency binaries or a fresh service build.

Detection uses Heni's generic diagnostic contract: passing baseline, successful
candidate build, test exit 1 and exact failing assertion-name output. Successful
test names are hidden. Structured test selection/counts remain unknown; human
Tasty transcripts provide the observed 11-test counts. The capacity fault causes
two relevant assertion failures, so these reports do not claim exclusive
named-failure attribution. No database, workflow, actual-model, Linux containment
or restart-recovery acceptance is implied.

See [repeat commands and limits](../../../tests/mutation/README.md) and
[ADR 122](../../adr/0122-deliberate-mutations-use-a-separate-haskell-tool-and-owning-tests.md).
