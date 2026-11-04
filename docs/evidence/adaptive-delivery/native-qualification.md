# Adaptive delivery native qualification

The first coupled trial on 2026-11-04 UTC failed during initial objective setup.
It does not qualify adaptive repository delivery, any recovery cut or the live
trial. No request or use-case acceptance is closed by this attempt.

The runtime was built from `64d9e4f4` as
`/nix/store/86b1rrqsqyqyl2dh76imp6smzzkg0k3q-shikigami-workspace-prototype-0.1.0.0-64d9e4f`.
The driver recorded source checkpoint `d4735a1f` with a dirty working tree; that
fact limits its source attribution. Its private attempt was
`build/adaptive-delivery-fixture/20261104T061012772850Z-fixture/manifest.json`.
The disposable arm64 Apple guest used native payloads and guards with the x86_64
Haskell controller outside their namespace. No host mounts, existing SSH keys or
model credentials were supplied.

Both repository-local checks passed and the initial combined journey correctly
failed. Native provisioning passed both original-identity/ready-acknowledgement
recovery checks. The native phase then exited 1 after 59.739 seconds. Its
`adaptive-admit.log` identifies the fixture's objective command path at
`Adaptive.hs:179`; no adaptive worker workspace had been allocated.

The fixture's initial assignment named a resource root while omitting its
cutoff. `Objective.Acceptance.validateGraph` explicitly requires both fields to
be present or both absent. The correction starts with the same unbound
assignment shape used by the qualified native coordinator tests; native
admission supplies the root and cutoff together. The shared initial assignment
now passes the executable host `adaptive-contract` check. Command failures also
name the fixture operation and objective error rather than discarding them.

Early-failure artifact collection separately encountered SQL NULL from an
empty binding aggregation. The runner now requests JSON `[]` for that case,
preserving an empty forensic inventory without claiming an artifact or a settled
effect. Subsequent failures retain bounded objective/receipt metadata as well as
the existing workspace diagnostics. A queued `2dce160d` build was stopped before
completion because it contained the same invalid initial assignment.

Run the cheap contract check before building a new immutable Linux runtime:

```bash
nix develop --no-write-lock-file -c cabal run workspace-linux-fixture -- adaptive-contract
```

It prints `PASS native adaptive initial assignment is valid before root/cutoff admission`.
This is a graph contract check; the corrected native baseline, transfer scenario,
remaining fault/refusal matrix and live trial still require actual execution.
