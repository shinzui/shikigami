# Governed repository workspaces

The configured durable worker offers file-only and supervised workspace hosts.
Enable it through the reviewed repository catalog and exact agent/principal
grants described in [configuration](configuration.md#governed-repository-files).
A Skill must declare `workspace.edit`, `workspace.exec` or `workspace.git` for
the corresponding tools; installing the host alone does not add
tools to a Skill. Historical workflow branches and snapshots retain their
original admission behavior.

Each assignment receives a private repository copy at an approved full commit.
Provider Git metadata is separate from mutable files. Admission freezes every
regular `AGENTS.md` blob and its directory scope from that commit, within the
instruction budget. Review the complete instruction digest before approving a
base. Editing an instruction file does not change the current assignment's
instructions; a later assignment must admit the new approved base.

## Process and Git qualification

The independent Linux supervisor, process-aware file adapter and local Git
adapter have passed the native accepted-executor qualification. An explicit
`workspaces.process` configuration installs them into the configured worker;
omitting it retains file revision 1. The normal parent/child workflow passes
the full fourteen-case native gate.
Handoff, integration and final IR-11 qualification remain delivery gates in
[plan 96](../plans/96-provide-governed-mutable-repository-workspaces-for-durable-agents.md).
Enablement requires the explicit reviewed process configuration and a qualified
image and containment profile.

The prototype uses systemd system services and writable cgroup v2, an immutable
execution root, separate reserved Unix identities, a private network and PID
namespace, and independent bounded output collection and deadline enforcement.
Unsupported hosts refuse execution. A command rule alone supplies no repository
containment. The supervisor owns the socket-activated listener and factual
receipt recovery independently of queue workers.

Run the native qualification in a disposable Apple container from the repository
root:

```bash
bash tests/workspace/run-apple.sh --prototype
bash tests/workspace/run-apple.sh --git
bash tests/workspace/run-apple.sh --workflow
```

The first command checks ten process/provisioning cases. The second includes
those cases plus accepted dependency edit, validation and local commit,
duplicate commit delivery, recovery after the committing worker is killed, and
fresh publication denial. It expects thirteen named cases overall.
`--workflow` additionally runs the
normal agent parent and execution child, restarts the worker after its accepted
edit, and verifies one terminal result with exact commit and validation evidence.
It passes fourteen named cases. The focused `--workflow-only` mode runs three
cases (native provisioning plus the normal workflow) for iteration; retain the
combined `--workflow` gate for complete process/Git/workflow qualification.
The runner builds its controller through the configured Nix builder, copies its closure
through Nix, creates a task-specific container and temporary SSH credentials,
and removes its container and credentials on exit. It prints the private
evidence directory. The fixture sources and runtime are copied without host
mounts or existing credentials.

Apple's periodic guest clock changes can expire the absolute deadline guard.
The fixture observes a clock change before admitting a short command and holds
restart cases until their intended boundary is established. It leaves clock
change protection enabled. Passing these short cases does not qualify commands
that must run across a guest clock change.

The trusted fixture controller uses `C.UTF-8` to load UTF-8 Dhall and Skill
files. Production workers also need a UTF-8 locale for those inputs. Repository
commands retain the separately cleared environment from their admitted rule.

## Local Git contracts

The local Git adapter is `workspace.git:1`, with namespaced `status`, `diff`
and `commit` tools. Exact operator installation, an explicit capability
declaration, the process-aware filesystem profile and a ready retained Unix
profile are all required. Tool description performs no repository IO.

Status and diff require whole-tree read permission. Capture enumerates ordinary
ASCII paths under the shared workspace lock after all retained processes have
settled. It refuses symlinks, hardlinks, special files and ambiguous case
spellings. Capture allows up to 100,000 entries, depth 128, individual blobs of
16 MiB and combined contents of 64 MiB; each directory allows at most 10,000
entries. Ordinary model file reads and edits retain their separate 256 KiB
limit. Git results are bounded to 32 KiB, so a larger diff refuses.

A commit accepts only an exact expected parent and a nonempty message of at
most 4096 UTF-8 bytes. It requires a nonempty change set of at most 256 paths,
and every changed path must satisfy the frozen write policy. Object construction
uses literal captured bytes, preserves executable intent and runs without
worktree filters, hooks, signing, external diff helpers or transport. It retains
the exact parent, tree, result and changed paths before conditional HEAD
publication. A second fresh C13 authorization binds that candidate immediately
before publication admission. No push or pull-request operation is provided.

## Recovery and retained evidence

Retain the database, protected payloads, private metadata and accepted policy
while operations remain pending. An expired lease, free file lock or exited
main PID does not establish settlement. Process receipts require complete
bounded output and matching boot/invocation evidence with every descendant
settled. Successful validation requires a confirmed normal exit with code zero.

An interrupted commit is reconciled by observing its exact retained result.
A prepared candidate alone cannot establish completion. Once publication
admission has been consumed, recovery cannot update HEAD again. Missing or
conflicting evidence leaves the workspace unavailable to other operations.
The independent receipt owner can acknowledge the original actual attempt
after execution authority is revoked or ownership freezes, without acquiring
authority to read model payloads or launch new work.

Do not repair exposed receipt-directory permissions and then trust its contents.
Do not remove pending workspace directories, replace receipt files, clear
reservations or recycle reserved Unix identities to regain capacity. Explicit terminal cleanup retains provider metadata and receipts. The operator commands
below are implemented; handoff and integrated-revision qualification remain open.

## Terminal cleanup

Use an active operator principal with fresh exact maintenance authority:

```bash
shikigami-worker --workspace-actor agent_01h000000000000000triage --workspace-list
shikigami-worker --workspace-actor agent_01h000000000000000triage --workspace-list --workspace-after RESOURCE
shikigami-worker --workspace-actor agent_01h000000000000000triage --workspace-cleanup RESOURCE
```

Supply the usual configuration containing `workspaces.storageRoot`, database
and action-authorizer settings. A list page has at most twenty public resource,
repository and base identities with cleanup status and terminal eligibility.
It omits local paths and instruction bodies. Its `next` cursor pages the
retained catalog. Cleanup takes exactly one retained resource identifier;
it does not accept a path or scan for directories to remove.

Cleanup requires a known terminal durable execution, no pending transport
receipts, every workspace effect/process settled and no live continuing session
sharing the resource root. Active, parked, unresolved and idle continuing
sessions retain their workspaces. Missing execution evidence refuses cleanup
of an unknown orphan. A terminal workspace whose worker has exited remains
eligible through its retained execution identity.

Before deleting files, the provider retains both root inode identities and the
expected Unix owner and permanently freezes admission under the shared lock.
Native deletion validates a complete bounded ordinary-file/directory tree,
refusing symlinks, hardlinks, special files, foreign ownership, filesystem
changes and substituted roots. The limit is 100,000 entries and depth 128 per
root. Interrupted deletion resumes only that exact plan; duplicate cleanup
observes its original completion. Files and scratch are removed, while Git
metadata, allocation markers, receipts, database rows and Unix identities
remain available for audit/recovery. This does not grant capacity by discarding
uncertain effects or provide general deletion of arbitrary host directories.
