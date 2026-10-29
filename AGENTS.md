## Haskell Record Fields

Follow `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md` for Haskell records. In particular, do not prefix record fields with the type, constructor, or module name; rely on `DuplicateRecordFields` and use direct field names such as `status`, `runId`, or `baseUrl`.

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

`bash tests/workspace/probe-apple-container.sh` demonstrates systemd, writable
cgroup v2, and effective PID, network, and capability isolation in an Apple
container. It installs the image's missing D-Bus package and removes its own
container on exit. Verify the capabilities each plan actually needs; this probe
does not qualify a durable supervisor, restart recovery, or workspace fencing.

`bash tests/workspace/probe-root-apple.sh` also verifies Nix and sudo availability,
a copied Nix closure inside an immutable systemd `RootDirectory`, unprivileged
workspace/scratch writes, effective PID/capability/syscall restrictions, and
whole-cgroup settlement of a detached SIGTERM-ignoring writer (13 checks).
This is substrate qualification; independent supervisor and receipt-recovery
qualification still belongs to the plan implementing those services.
