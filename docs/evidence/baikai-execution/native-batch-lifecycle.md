# Native batch lifecycle qualification — 2026-11-13 UTC

The eight public-adapter cancellation cases now pass on native Darwin/aarch64
and Linux/x86_64. Both entry points use
`shikigami-core/test-support/Shikigami/Behavior/BatchCliFixture.hs`; the core suite
wraps those cases in Tasty and the standalone executable runs them directly.
Fixture source is commit `ad8393913f8d12f87b126be215af58dd1b384c61`. Subsequent
changes remove one unused test import and update documentation. Exact source
hashes, artifact paths, counts and preliminary failures are retained in
[native-batch-lifecycle.json](native-batch-lifecycle.json).

All 866 core tests pass after the import cleanup. The committed workflow gate
passes 210 conformance assertions, reports replay-neutral and leaves generated
files unchanged. The focused behavior group passes 45 cases; the standalone
Darwin command passes eight. The selected public adapters remain core Baikai
0.10.1.0 and Claude/OpenAI 0.7.3.0 with the unchanged frozen cohort.

Apple container 1.5.0 stalled before registering either the existing systemd
image or a minimal native Nix guest. Those attempts were stopped without
restarting the shared service; neither task container exists, and the generated
SSH key, public key and known-host file are absent. FRIC-70 accepts the configured
builder fallback. This checkpoint qualifies native x86_64 Linux; it does not
claim arm64 Linux or translated execution.

The final fixture builds offline from verified frozen descriptors and installs
only its executable and cohort record. It links no Shikigami application library
and enters no deployment package. Build and run the exact Linux output:

```bash
nix build .#packages.x86_64-linux.shikigami-baikai-contracts \
  --max-jobs 0 --cores 2 --no-link --no-write-lock-file --json
ssh -o BatchMode=yes -o ConnectTimeout=60 builder@nix-gcp-builder /bin/bash -s <<'LINUX'
set -euo pipefail
probe_home=$(mktemp -d /tmp/shikigami-plan80.XXXXXX)
trap 'rmdir "$probe_home"' EXIT
cd "$probe_home"
/usr/bin/env -i PATH=/usr/bin:/bin HOME="$probe_home" TMPDIR="$probe_home" \
  /usr/bin/timeout 120 /nix/store/b93ahqimn9rg51gbnwrrl3h33mfwz6y2-shikigami-baikai-contracts-0.1.0.0-fixture/bin/shikigami-baikai-contracts +RTS -N2 -RTS
LINUX
```

For another source candidate, substitute the `outputs.out` returned by its build.
The Linux host must provide `/bin/ps`, `/bin/kill`, a POSIX shell and `sleep`.
The successful run, with a temporary HOME/TMPDIR and cleared environment, prints:

```text
Batch CLI inherited-group qualification: linux/x86_64
PASS AnthropicMessagesCli/complete
PASS AnthropicMessagesCli/complete-resistant-repeated
PASS AnthropicMessagesCli/stream-resistant-repeated
PASS AnthropicMessagesCli/version-probe
PASS OpenAICompletionsCli/complete
PASS OpenAICompletionsCli/complete-resistant-repeated
PASS OpenAICompletionsCli/stream-resistant-repeated
PASS OpenAICompletionsCli/version-probe
PASS 8 lifecycle cases; batch bounds/confinement remain unqualified
```

Each case verifies the original asynchronous exception, stopped parent and
inherited child, an unrelated live sentinel, and Codex schema cleanup where
applicable. Resistant cases repeat cancellation. The version case cancels the
actual evidence-version subprocess. These are fake vendor executables, with no
login, API key or remote model call.

The driver's 120-second outer timeout supplies no production deadline contract.
FRIC-69 remains logged: the released adapters ignore `Options.timeoutMs`, retain
output to EOF, and do not confine detached descendants or vendor-native tools.
Their documented boundary is `mori://shinzui/baikai/docs/cli-providers`.
`BatchBoundsAndConfinementRequired` remains in force. M1's native Linux lifecycle
proof is complete; M1's bounds/confinement gate, M2/M3 CLI promotion, M6's
authenticated reporter and M5's final qualification after those future runtime
changes remain open. Prior HTTP/structured installed evidence retains its
original source attribution in [consumer-matrix.md](consumer-matrix.md).
