# Deliberate Haskell mutation pilot

This pilot uses the separately built `mori://shinzui/heni` CLI, version 0.1.0.0.
Heni applies checked edits, proves passing baselines, runs candidates and writes
reports. The project does not depend on Heni's library or Tasty reporter.

Run from the repository root:

```bash
mkdir -p .dev/heni/bin
nix develop --no-write-lock-file -c cabal install --ignore-project heni-cli-0.1.0.0 --installdir=.dev/heni/bin --install-method=copy -j2
nix develop --no-write-lock-file -c cabal build shikigami-core-test
nix develop --no-write-lock-file -c cabal exec -- "$PWD/.dev/heni/bin/heni" check tests/mutation/heni.json
nix develop --no-write-lock-file -c just mutation-tests .dev/heni/bin/heni mutation-results/pilot
```

Pass an executable path as the recipe's first argument. Use a new output directory
for each run; Heni refuses existing outputs. Installation uses an independent
dependency solve, leaving the project's frozen cohort intact. Repeat installation
can use Cabal's `--overwrite-policy=always` for this private executable directory.

The `pilot` tag selects three deliberate implementation faults and one unchanged
control:

| Case | Fault | Required result |
| --- | --- | --- |
| `finite-capacity` | Disable the finite capacity guard. | Capacity assertion fails. |
| `billing-completeness` | Accept settlement missing reserved billing dimensions. | Incomplete-settlement assertion fails. |
| `stale-root-revision` | Ignore the expected root revision. | Revision assertion fails. |
| `unchanged-control` | No edit. | The owning suite passes. |

The successful pilot exits zero. Its report distinguishes the three semantic
detections from the passing control. Inspect a retained report without rerunning:

```bash
.dev/heni/bin/heni report mutation-results/pilot/report.json
```

Two deliberately unmet contracts qualify the runner integration:

```bash
nix develop --no-write-lock-file -c cabal exec -- "$PWD/.dev/heni/bin/heni" run tests/mutation/heni.json --tag negative-control --output mutation-results/controls
.dev/heni/bin/heni report mutation-results/controls/report.json
```

This command must exit **1**. `survivor-control` changes only a comment and must
report `Survived`. `compile-error-control` references a missing identifier and
must report `UnexpectedBuildFailure`, rather than a caught semantic fault.
Running the manifest without a tag includes these intentionally failing controls.

`Build.hs` is only a compilation adapter. It invokes GHC with the production
`Shikigami.Execution.Resources` module, its existing `ExecutionResourcesSpec` and
the small `Main.hs` test entry point. It forces fresh compilation, clears implicit
source search paths and writes artifacts into the candidate's private workspace.
All other imports use the project's already built dependency units through the
temporary `GHC_ENVIRONMENT` supplied by `cabal exec`. Keep that parent command
alive throughout the campaign. The adapter interpreter uses `-package-env -` so
it loads only its own standard-library dependencies; the compiler child still
inherits the project's package environment.

The manifest captures only these source files and the pilot directory. No build
cache is copied into candidates or reused across them. The host's compiled
dependency package databases must remain unchanged during a campaign. Preparing
them with `cabal build shikigami-core-test` is part of the recipe, outside Heni's
source snapshot. This is focused recompilation of a pure module, not a fresh
whole-service build or an independent proof of the dependency cohort.

The generic evidence contract requires a passing baseline, a successful candidate
build, test exit 1 and the exact assertion-name diagnostic. Tasty uses
`--color never --hide-successes`, so passing assertions do not emit those
diagnostics. Heni's structured test IDs/counts remain unknown; this pilot does not
install `heni-tasty`, claim exclusive named-failure attribution or measure
repository-wide mutation coverage. Raw Tasty output supports human inspection.
No database, workflow, actual-model or process-containment qualification is implied.

For Heni's contract reference, see `mori://shinzui/heni`, project-relative paths
`docs/user/manifest-reference.md` and `docs/user/adapters.md`; artifact-level URIs
are pending. Published pilot results live in `docs/evidence/mutation/`.
