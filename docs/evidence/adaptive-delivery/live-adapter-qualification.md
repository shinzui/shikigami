# Guarded live adapter qualification — 2026-11-09

The live composition and its key-free guards are implemented. Plan 86 milestone
3 remains open: no actual-model/production-authority trial has been run, and
trusted invoice reconciliation is not selected or wired. These results do not
close UC-1 or IR-16.

The candidate was prepared from baseline `ec3e1c6c` with the recorded working-tree
changes. [Source hashes](live-adapter-source.json) identify the exact implementation
files, immutable runtime and derivation. The Linux runtime is
`/nix/store/05yi39ncc8rkxji2ag8jm3wdhgc64gx2-shikigami-workspace-prototype-0.1.0.0-dirty`.
Its derivation identifies the physical qualification candidate. After that run,
repository formatting normalized imports/layout and module comments were clarified.
The source record distinguishes qualified bytes from the final normalized files;
the local fixture build and eight CLI controls were rerun after normalization. The frozen
cohort is declared in `nix/qualification/cohort.json`; no dependency bounds,
workflow bodies, domain contracts or migrations changed.

The host checks passed:

```bash
nix develop --no-write-lock-file -c cabal build all
nix develop --no-write-lock-file -c cabal build workspace-linux-fixture
nix develop --no-write-lock-file -c cabal run workspace-linux-fixture -- adaptive-contract
nix develop --no-write-lock-file -c python3 tools/qualification/test_adaptive_live.py --native-preflight
python3 -m unittest discover -s tools/qualification -p 'test_*.py' -v
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-core-test shikigami-server-test --test-show-details=direct
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-core-postgres-test --test-show-details=direct
TASTY_NUM_THREADS=2 nix develop --no-write-lock-file -c cabal test shikigami-workers-test --test-show-details=direct
nix develop --no-write-lock-file -c just migration-schema-isolation
```

The Python suite passed 62 cases in 15.184 seconds. The native CLI preflight
passed eight controls on macOS and again inside Linux: explicit HTTP
configuration succeeds; stub behavior, disabled authority, unbounded tokens,
finite invoice ceilings, missing roles, missing keys and missing request timeouts
refuse. Injected ambient provider/key variables cannot override the private file
or satisfy a missing key. These controls use synthetic credentials and make no
model or production-authority request.

The Haskell suites passed 787 core, 114 server, 681 PostgreSQL and 353 worker
cases, totaling 1,935. Database suites ran serially with two Tasty threads and
owned ephemeral PostgreSQL fixtures. The worker suite's Plan 113 artifact was
restored to its exact pre-test bytes as documented by FRIC-65. Migration isolation,
shell syntax and whitespace checks pass.

The candidate also passed the complete physical fixture:

```bash
python3 tools/qualification/adaptive-delivery.py --mode fixture \
  --config build/adaptive-delivery-config/final-live-fixture.json \
  --artifact-dir build/adaptive-delivery-live-regression
```

Its native phase took 448.297 seconds. [Fixture facts](live-adapter-fixture-facts.json)
retain the passing verdict, root accounting, identities and exact artifacts;
[recovery records](live-adapter-fixture-recovery.json) retain actual native receipt
and outcome projections. Both integrated trees were independently recomputed
from all six returned Git bundles, and the journey passed on the returned exact
pair. The eight Linux live preflight controls run before objective admission.
The full adaptation/result/follow-up/ownership/unknown-edit/refusal matrix and
terminal replay also pass. The guest and generated SSH credentials were removed.
These remain scripted-model/disposable-issuer results, not paid-model proof.

The live path selects only existing production HTTP handlers, without creating
responses or usage evidence. Private JSON supplies the five role bindings,
production authorizer and finite model/tool/token/active/descendant limits.
Format-3 verification binds independent admission to the operator's source specs,
physical handler response identities and caps, coordinator/worker receipts,
settled native accounting, continuing-session adaptation and exact artifacts.
Native resource maps use key/value-pair arrays. Thinking descriptors and provider
thinking translations retain their distinct native encodings. Authority
`checkedAt` is an opaque consistency token; the production client verifies proofs
and expiry before IO, while the retained audit projection excludes proof/token
bytes and checks complete unique verifier coordinates.

Failures preserve bounded root/call/authority/dispatch facts and available Git
bundles without settling uncertainty or claiming completion. The host removes
its staged credential file on success and failure; live mode creates neither
fixture authorization issuer and copies no host mounts or ambient credentials.
The [templates and runbook](../../../tests/adaptive-delivery/README.md) make the
remaining private inputs reviewable.

The built-in HTTP assemblers calculate estimated invoice cost. The existing
selection owner accepts only measured provider billing or trusted reconciliation,
so credentials alone cannot obtain successful objective completion. The current
direct verifier requires measured settled facts; a trusted reconciliation source
and its independently linked evidence still need selection and integration.
No zero-cost substitution or relaxation of the accepted resource owner was made.
FRIC-66 is resolved by the restored Mori tunnel. FRIC-67 records the cold native
dependency-cache cost; the completed cache was reused for this final candidate.
