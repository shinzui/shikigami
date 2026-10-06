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
python3 tools/qualification/export-cohort.py --plan /absolute/path/to/plan.json \
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

`snapshot.py --inventory PATH --marker PUBLIC_MARKER` reads a JSON inventory with
a `health_endpoints` object mapping short service names to explicit numeric
loopback HTTP URLs, for example `http://127.0.0.1:8081/health/ready`. It probes only
the allowed health paths with bounded requests and never copies response bodies.
The resulting JSON is a supplied observation, not evidence of agent-owned polling.

See the [readiness report](../../docs/evidence/local-qualification/readiness.md)
for tested revisions and the service startup order. Keep credentials in private
configuration; provide credential-file paths rather than secret values.
