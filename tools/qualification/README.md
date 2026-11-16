# Local qualification tools

These tools implement the baseline and preparation portions of
[plan 79](../../docs/plans/79-qualify-local-agent-execution-and-prioritize-production-readiness.md).
Host, reporter, recovery and approval phases remain blocked and are not implemented
by the driver yet. Their command names deliberately return a blocked result.

Run from the repository root:

```sh
python3 -m unittest discover -s tools/qualification -p 'test_*.py' -v
mkdir -p "$HOME/.local/state/shikigami/qualification/evidence"
chmod 700 "$HOME/.local/state/shikigami/qualification/evidence"
bash tools/qualification/check.sh --phase baseline \
  --config "$HOME/.config/shikigami/qualification/runtime.yaml" \
  --artifact-dir "$HOME/.local/state/shikigami/qualification/evidence"
```

The baseline does not require that configuration file to exist. It isolates the
committed Cabal project from ignored overrides, uses the declared development
shell for native dependencies, and runs PostgreSQL tests against disposable
instances owned by the tests. Every case has a bounded timeout, private log and
machine-readable result. An expected failing ambient solve still makes the overall
baseline exit nonzero; inspect individual cases in `summary.json`.

To export the successful isolated solve for immutable packaging, substitute its
actual `dist-newstyle/cache/plan.json` path:

```sh
cabal path
python3 tools/qualification/export-cohort.py --plan /absolute/path/to/plan.json \
  --index /absolute/remote-repo-cache/hackage.haskell.org/01-index.tar \
  --output nix/qualification
git add nix/qualification/cohort.json nix/qualification/metadata.tar.gz \
  nix/qualification/vendor/kikan-en.tar
nix build --no-link .#shikigami .#shikigami-server .#shikigami-worker .#shikigami-migrate
```

The exporter consumes exact descriptor hashes from the secure Cabal index and
pins fetched source trees. It requires a clean compatible Kikan-En checkout and
archives its contract/client trees when they are not published. Metadata files
are ignored working files; the deterministic archive is the packaging input.
All role packages expose schema and qualification assets under
`share/shikigami`; installed skill manifests refer to installed skill paths.

The PostgreSQL test executable has an explicit installed judgment mode. Build it
with the isolated project, then supply absolute paths to the packaged operator,
worker and installed proof-agent directory:

```sh
nix develop --command cabal build shikigami-core-postgres-test \
  --project-file="$qualification_project"
qualification_test=$(nix develop --command cabal list-bin shikigami-core-postgres-test \
  --project-file="$qualification_project")
nix develop --command "$qualification_test" --installed-judgment \
  /absolute/operator/bin/shikigami /absolute/worker/bin/shikigami-worker \
  /absolute/agents/directory
```

The judgment example is a flow of `packs/flow-pack-examples` since plan 131 (M2). The stock
worker no longer has it and the runtime package no longer ships its manifest, so pass a
worker composed with that pack and the pack's `agents` directory. A Nix package of a
distribution does not exist yet.

The driver provisions PostgreSQL and a loopback TypeSafe fixture, runs the actual
installed commands from a disposable directory with a temporary HOME and cleared
credential environment, and checks configuration, enqueue, worker execution,
duplicate enqueue after restart, retained raw/derived answers and one total HTTP
request. It refuses relative paths and never substitutes checkout executables.
The separate native restart test covers a crash between decision commitment and
workflow completion; duplicate installed enqueue does not claim that fault proof.

The batch CLI lifecycle fixture reuses
`shikigami-core/test-support/Shikigami/Behavior/BatchCliFixture.hs` from the core
suite. It links only the selected public Baikai adapters and runs eight fake
vendor cases, with no login or API key. It checks inherited process groups,
active synthetic streams, repeated cancellation, resistant children, executable
version probes, schema cleanup and an unrelated sentinel. It does not qualify
batch deadlines, output bounds, detached descendants or reporter confinement.

Prefer a disposable native Apple Linux guest:

```sh
bash tests/workspace/build-apple.sh \
  packages.aarch64-linux.shikigami-baikai-contracts bin/shikigami-baikai-contracts
```

The optional `bin/<executable>` argument runs the exact built artifact in that
guest, in a cleared environment under a 120-second outer fixture timeout. The
helper retains `result.json` and `probe.log` in its printed temporary directory.
The outer timeout protects the qualification driver; it supplies no production
batch deadline contract.

If Apple startup is unavailable, build the x86_64 fixture with the configured
builder, then execute that exact output on native Linux. Retain the JSON output
and use its `outputs.out` path; do not substitute a Darwin build or count
translation as native arm64 qualification:

```sh
nix build .#packages.x86_64-linux.shikigami-baikai-contracts \
  --max-jobs 0 --cores 2 --no-link --no-write-lock-file --json
```

The Linux host needs `/bin/ps`, `/bin/kill`, a POSIX shell and `sleep` on `PATH`.
Run with a temporary HOME/TMPDIR and a cleared environment. Success prints
`linux/x86_64` (or the actual native architecture), eight `PASS` cases and the
explicit statement that batch bounds/confinement remain unqualified. The fixture
has its own optional Cabal package, `baikai-cli-fixture`; it does not enter the
seven-package runtime export or add a deployment command.

`snapshot.py --inventory PATH --marker PUBLIC_MARKER` reads a JSON inventory with
a `health_endpoints` object mapping short service names to explicit numeric
loopback HTTP URLs, for example `http://127.0.0.1:8081/health/ready`. It probes only
the allowed health paths with bounded requests and never copies response bodies.
The resulting JSON is a supplied observation, not evidence of agent-owned polling.

See the [readiness report](../../docs/evidence/local-qualification/readiness.md)
for tested revisions and the service startup order. Keep credentials in private
configuration; provide credential-file paths rather than secret values.


The current 0.22 export and bounded macOS qualification are recorded in
`docs/evidence/keiro-0.22/macos-final-qualification.json`. Obtain the index path
from `cabal path`; Cabal's XDG cache need not be `~/.cabal/packages`. The current
export is not evidence of a cold Nix or Linux build. Run the scoped inventory
gate with `python3 tools/qualification/keiro_022_audit.py`; it verifies sources
through canonical Mori project roots and permits only the named plan108 follow-up.
