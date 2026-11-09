## Prefer Haskell

Always prefer Haskell for new implementation, tooling, and tests. Test Haskell-owned
behavior through its native APIs or executable. Consolidate overlapping coverage
at the owning layer instead of adding a second domain model or validation suite
in Python. Keep scripting glue small; retain Python tests only where they verify
remaining Python behavior or an integration boundary that requires it.

## Haskell Record Fields

Follow [the record patterns guide](mori://shinzui/haskell-jitsurei/docs/core-record-patterns) for Haskell records. In particular, do not prefix record fields with the type, constructor, or module name; rely on `DuplicateRecordFields` and use direct field names such as `status`, `runId`, or `baseUrl`.

## Durable Workflow Changes

Shikigami runs agent runs and Danwa conversations as durable keiro workflows whose
journals outlive the code that wrote them. **Any change to a workflow body — under
`shikigami-core/src/Shikigami/Agent/` or `shikigami-core/src/Shikigami/Flow/` — must
follow [docs/workflow-versioning.md](docs/workflow-versioning.md).** It states which
step-shape changes are deploy-safe, when `patch` and `continueAsNew` are required, and
how a patch id is declared in `domain/` and gated by `just keiro-gate`.

## Linux Qualification on macOS

Use Apple containers as the preferred Linux qualification environment on this
Mac. The container service is installed and running. Do not ask the user whether
a Linux environment is available for each new plan: inspect the existing setup
and provision a disposable, task-specific container without host credentials or
unnecessary host mounts. Use the configured Nix remote builder as the fallback
when Apple containers cannot meet the task's requirements.

`bash tests/workspace/build-apple.sh` builds the Linux runtime in a disposable
Apple container and copies its outputs back through Nix. An optional argument
selects another `packages.aarch64-linux.<package>` attribute. It generates a
temporary SSH key, verifies the guest's host key, publishes SSH only on loopback,
uses two build cores, and removes its container and generated credentials
on exit. Cabal configuration has also stalled at two cores (FRIC-21); use the
configured remote builder for a stalled build and retain Apple containers for
runtime qualification. It uses no host mounts or existing SSH credentials. Compilation alone
does not qualify runtime containment, restart recovery or workspace fencing.

`bash tests/workspace/probe-apple-container.sh` demonstrates systemd, writable
cgroup v2, and effective PID, network, and capability isolation in an Apple
container. It installs the image's missing D-Bus package and removes its own
container on exit. Verify the capabilities each plan actually needs; this probe
does not qualify a durable supervisor, restart recovery, or workspace fencing.

`bash tests/workspace/probe-root-apple.sh` also verifies Nix and sudo availability,
a copied Nix closure inside an immutable systemd `RootDirectory`, unprivileged
workspace/scratch writes, effective PID/capability/syscall restrictions, and
whole-cgroup settlement of a detached SIGTERM-ignoring writer, and the production
Nix deadline-guard closure under that immutable root (14 checks).
This is substrate qualification; independent supervisor and receipt-recovery
qualification still belongs to the plan implementing those services.

`bash tests/workspace/probe-socket-apple.sh` qualifies adoption of the exact
private Unix listener supplied by systemd, kernel peer credentials, descriptor
flags, refusal of another endpoint, and retention of that listener across
SIGKILL and service restart (4 checks). It is listener substrate evidence;
accepted-attempt recovery still requires the full supervisor fixture.

`bash tests/workspace/probe-provision-apple.sh` checks the native directory
provisioning, owned-file publication and Git enumeration primitives (14 cases). It refuses
symlinks, hard links, FIFOs, root identities and substituted roots before
ownership changes, recovers partial changes for the same reserved identity,
and verifies service access to newly published files under the production
containment properties. It does not qualify account creation, coupled durable
admission or supervisor restart recovery.

`bash tests/workspace/probe-collector-apple.sh` qualifies the independent bounded
output collector and absolute deadline guard using the compiled production
systemd properties (18 cases).
It covers output draining, duplicate-unit refusal, cancellation, timeout,
collector loss, mismatched evidence, metadata privacy and literal arguments in
a cleared environment. It also checks queued and expired starts, orphan
descendants, retained exit status and protection of the trusted deadline parent.
It also injects a disposable guest clock change and requires early expiration
plus complete descendant settlement.
Cancellation checks also reject another boot, invocation or fingerprint. The
default arm64 probe passes; the optional `amd64` probe currently fails its first
isolated payload under translation (FRIC-22). Qualify the architecture and
containment profile actually used by a plan.
Full supervisor RPC, accepted launch and restart
qualification remain separate gates; this probe does not enable process tools.

`bash tests/workspace/run-apple.sh --prototype` runs the coupled accepted-executor
fixture with native arm64 payloads/guards and a configured-builder Haskell
controller outside the command namespace. All ten provisioning, owned-edit,
duplicate, restart, cancellation, isolation and receipt-recovery cases pass.
This does not enable configured process tools or qualify Git commits/handoff.

Apple container 1.5.0 synchronizes guest realtime every thirty seconds (FRIC-24).
That clock step correctly expires the production absolute-deadline guard. The
fixture observes a clock step before short command admission and releases held
commands only after checking the intended restart boundary. Keep clock-change
protection enabled; do not treat these results as qualification for long-running
commands across clock changes.
