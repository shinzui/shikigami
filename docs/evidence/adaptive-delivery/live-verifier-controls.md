# Live verifier controls — 2026-11-09

Plan 86 milestone 3 remains open. These controls qualify worker-evidence and
root-envelope verification helpers, not a live dispatcher or actual-model trial.
The executable driver still refuses live mode. No paid model request or
production authorization request was made for these checks.

At baseline `217dd7bde45743d5ab425434783e479efa92e3a6`, with the verifier changes
in the working tree, this command passed all 54 cases in 13.519 seconds:

```bash
python3 -m unittest discover -s tools/qualification -p 'test_*.py' -v
```

Four new test groups exercise exact independent admitted descriptors with
variable worker call counts, scripted-binding refusal, receipt/transport/usage
mismatch refusal, and finite root limits with settled-work requirements.
The existing fixture, exact returned-artifact tamper checks and live-mode
refusal controls still pass. Shell syntax and whitespace checks also pass:

```bash
bash -n tests/workspace/run-linux.sh
git diff --check
```

`validate_worker_selections(..., admitted=...)` compares complete credential-free
model descriptors, including alias, binding versions, provider, API, endpoint
class, exact model and thinking. Calls must link to the selection owner's stored
receipt and outcome for the same assignment, operation, attempt, ordinal and root.
The checks require successful model-observed HTTP facts, matching requested and
reported models, measured tokens and known billing. The ordinary fixture path
continues to require its deterministic bindings and original call-count bounds.
The Linux snapshot exports complete stored receipt/outcome records, containing
resource and compliance metadata rather than provider credentials or prompts.

`validate_live_root` checks the independently admitted envelope and admission
time, finite concurrency/descendant/model/tool/token limits, a cutoff at most
one hour after admission, explicit unsupported invoice-ceiling policy, and no
active, unknown, cancelled, exceeded or held work. It rejects settled quantities
above the admitted limits. This helper does not enroll a root or enforce limits
on a transport; those remain responsibilities of the existing runtime owners.

The live composition still needs private configuration validation, real provider
and production authorization dispatch, admitted-root wiring, coordinator-call
verification and the complete live evidence consumer. Exact artifact checks
remain mandatory. These helper tests cannot establish those missing gates.
Dependency-source discovery is blocked by the configured Mori PostgreSQL tunnel
(FRIC-66 in `docs/friction-log/`); an independent local database has no Mori
registry. No empty replacement registry was created.

The full native consumer also passed with the expanded snapshot export:

```bash
python3 tools/qualification/adaptive-delivery.py --mode fixture \
  --config build/adaptive-delivery-config/owner-transfer.yaml \
  --artifact-dir build/adaptive-delivery-verifier-check
```

The native phase took 448.241 seconds and the driver returned `state: passed`.
[Retained facts](live-verifier-native-facts.json) identify the dirty driver
candidate at the baseline above and reused immutable runtime `5ee0dd83`.
This rechecks the shell export and fixture consumer with that runtime; it does
not rebuild or qualify the current Haskell source. All five worker assignments
retain ten complete [receipt/outcome records](live-verifier-native-recovery.json); the recovery document is 43,298
bytes, within its existing 64 KiB bound. Both worker pairs were independently
reintegrated from the six returned Git bundles and the exact combined journey
passed. The selected runtime's full restart, uncertainty, transfer and refusal
matrix also passed. The container and its generated credentials were removed.
The live model/production-authority limitation remains explicit in the verdict.
