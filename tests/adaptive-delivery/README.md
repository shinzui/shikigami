# Finite adaptive delivery qualification

This fixture belongs to [Plan 86](../../docs/plans/86-qualify-integrated-adaptive-autonomous-delivery.md).
It prepares two disposable Git repositories, never an operator checkout. The
canonical identities are `mori://fixture/adaptive-producer` and
`mori://fixture/adaptive-consumer`. They are local qualification identities;
they grant no access to another repository or a remote Git service.

The producer emits version 2 at `value.text`. The consumer initially expects
version 1 at `text`. Both repository-local checks pass on their own samples.
The independent journey fails until a retained producer finding causes a
same-session consumer correction to version 2. A coordinator also assigns one
bounded reviewer in each repository, so two retained commits per repository can
be combined in a separate integration workspace. The planner requires a common
base within one repository; it does not merge commits across repositories.

The deterministic starting commits are:

| Repository | Commit | Tree |
| --- | --- | --- |
| `mori://fixture/adaptive-producer` | `02dd5ee5e300a00f187d455f5f9edf9d58279c9f` | `de975070714af54cda16b0e90508dcd29b44f4be` |
| `mori://fixture/adaptive-consumer` | `5040a3c99659fba0355324811a666884c0297217` | `b9f280df0ae47379916ae088fe55b66acd06b0cb` |

Full Git object IDs are scoped by those canonical fixture repository identities;
the artifact-level Git URI convention is pending.

`prepare.py` fixes author, timestamp, object format, branch and file modes and
ignores ambient Git configuration. Repeated preparation in fresh directories
produces the same objects. It refuses to overwrite an existing attempt. Changing
a template intentionally changes its base; update the table after verifying
reproducibility. Each repository contains its own frozen `AGENTS.md`.

From the repository root, prepare an isolated mechanics attempt:

```bash
python3 tests/adaptive-delivery/prepare.py --directory build/adaptive-seeds
python3 build/adaptive-seeds/producer/local_check.py
python3 build/adaptive-seeds/consumer/local_check.py
python3 tests/adaptive-delivery/journey.py \
  --producer build/adaptive-seeds/producer/record.json \
  --consumer build/adaptive-seeds/consumer/contract.json
```

The first two checks exit zero. The journey exits one with a schema-version
mismatch. The intended corrected consumer contract is
`{"version":2,"path":["value","text"]}` followed by a newline. The corrected
journey must print `combined journey passed: hello` and exit zero. A manually
corrected seed proves fixture mechanics only.

The qualification driver accepts JSON-form YAML without an additional Python
dependency. `fixture.yaml` admits only the two identities, a 1,800-second
driver timeout and 48 actual model attempts. As shipped it has no machine-specific
runtime path, so this command demonstrates the mechanics and returns blocked:

```bash
python3 tools/qualification/adaptive-delivery.py --mode fixture \
  --config tests/adaptive-delivery/fixture.yaml \
  --artifact-dir build/adaptive-delivery-fixture
```

The driver creates a private attempt directory and manifest. Logs are bounded
to 1 MiB each, child process groups have deadlines, and ambient database/provider
configuration is not inherited. `state: passed` is reserved for all required
native proof. A native command failure is `failed`; an unavailable prerequisite
or unfinished gate is `blocked`. Both exit nonzero. No model credentials are
required in fixture mode.

The native consumer is `tests/workspace/prototype/Adaptive.hs` in the existing
`workspace-linux-fixture` Cabal package. Build it locally for compiler checks:

```bash
nix develop --no-write-lock-file -c cabal build workspace-linux-fixture
```

The actual Linux fixture uses the existing disposable Apple-container runner:

```bash
bash tests/workspace/run-apple.sh --adaptive-only
```

An optional second argument selects an explicitly built Nix runtime output;
the driver requires that output as `runtime` in a private copy of `fixture.yaml`.
Compile the runtime before bounded objective admission; a cold build must not
consume the objective's execution deadline. The template driver never starts
an implicit cold build. This does not establish that an older output qualifies
the current source; record the actual selected output and source versions.
There are no host mounts or inherited SSH credentials. The runner creates its
own guest database, temporary authorization issuer and native immutable process
root. It uses the production authorization client and proof verifier, real
workspace accounts, supervisor and factual receipts. A deterministic issuer is
fixture evidence, not a live production authority service.

The controller admits a finite objective through the normal enqueue adapter and
the registered `adaptive-delivery` Flow. Each role has a different allowed model
alias. The 48-attempt root cutoff is 1,200 seconds; individual model runs and
checks retain bounded deadlines. The fixture provider performs zero paid
transport work. Token and invoice limits are explicitly unbounded for these
key-free calls; these settings must never be described as an enforceable live
cost policy. The independent combined check reads blobs from the exact two
integrated trees, not mutable worker paths. Its verifier-owned attestation pins
both resulting commits, and its artifact reference commits the full retained
integration facts. The model proposes completion; the objective owner accepts it.

The trusted integration controller drives accepted tool contracts without a
final model turn, then explicitly stops those two fixture executions. Their
failed terminal status supplies settlement, not successful check evidence:
the owner uses the separate factual Git receipts, zero-exit native validations
and exact-pair journey. Worker coding still traverses normal native Skill
executions. Live integration behavior remains a separately required trial.

The shell injects process death after an adaptive decision commits but before
the journal acknowledges it, then reconstructs the controller over the retained
database. It also observes an accepted tool outcome, an unconsumed worker result
and an accepted follow-up, stops the controller cgroup, rechecks the committed
owner record and kills that cgroup before starting another controller. The
independent workspace supervisor and payload units survive these controller
faults. Result and wake publication share one owner transaction; the result cut
precedes consumer integration, rather than inventing an unpublished-wake gap.
A final completed-run replay must preserve the entire evidence object and the
provider-call bytes. Each cut retains private receipt metadata in
`adaptive-recovery.json`. These probes still require their first Linux run.
The complete coupled fault/refusal matrix in milestone 2 remains a
separate acceptance gate. Native compilation alone proves none of these runtime
claims. The driver retains that gate as blocked until the full matrix exists.

Before the guest is destroyed, `archive.py` exports bounded local Git bundles
from its authoritative fixture workspace bindings. A successful run must retain
all four worker commits and both combined commits. A failed run preserves the
available HEADs as forensic artifacts without declaring unknown effects settled.
The private evidence directory contains `adaptive-artifacts/manifest.json` and
the bundles; use `git bundle list-heads FILE` or clone a bundle into a fresh
directory for inspection. This archival read is performed by the trusted fixture
controller and is not agent publication authority.

The host driver independently fetches each returned bundle into a fresh bare
repository, checks its exact HEAD and single admitted base parent, and runs
`git fsck --strict`. It recomputes each integration tree from the two retained
worker commits with `git merge-tree --write-tree`, compares that tree with the
accepted combined commit, and reruns the journey on blobs from the returned
combined trees. These checks use no guest workspace paths. A hash of arbitrary
bytes, an omitted reviewer change or an obsolete consumer contract cannot
supply passing artifact evidence. The attempt manifest records the selected
runtime output separately from the driver's source revision.

`--mode live` currently returns blocked. No private live provider configuration
has been supplied and no live adapter is selected. Live acceptance additionally
requires an actual model-driven coding path, production authorization, explicit
attempt/duration/token policy, fresh service readiness, and retained evidence.
Baikai's Codex CLI transport and Shikigami's foreground/unattended launch wrapper
already exist, but are not the admitted durable response path used here. The
current response guard refuses `codex-cli` until bounded output, deadlines and
descendant confinement are qualified; a foreground process result alone cannot
complete this objective. See [the execution runbook](../../docs/operations/baikai-execution.md).
It must never fall back to the deterministic provider. No publication, merge,
deployment or recurring mandate is authorized by this fixture.
