# Live HTTP contract

Run the safe suite against an explicitly chosen listening service:

```bash
bash shikigami-api/test/hurl/run.sh http://127.0.0.1:8080 /private/path/hurl-secrets.env
```

The private Hurl secrets file supplies `token=…`; no real credential belongs in
this directory or in a report committed to Git. Hurl redacts exact secret values
in diagnostics; response bodies and JSON reports still need controlled handling.

The default list is explicit: health, agent catalog, generic problems and the
live OpenAPI document. The catalog fixture has exactly two declarations named
`disabled-heartbeat` and `heartbeat`, with the disabled declaration sorting first.
Directory mode is disabled (`unverified`), the server uses bearer authentication,
and heartbeat is deterministic with no external sinks. Each file is independent;
Hurl may execute the safe files in parallel. No default request mutates domain
state (the unsupported POST probe only proves method rejection).

`auth.hurl` is an opt-in perimeter suite for that bearer profile. `agent-runs.hurl`
is an opt-in write suite against a fresh writable fixture. Its accepted/replayed
request, conflict and subsequent public reads share captures within that file
only. The `hurl-1` identity is reserved for it; rerunning on a populated fixture
would start with replay rather than 202 and must be done with a fresh clone.

`unavailable.hurl` is opt-in after the owning orchestrator stops its disposable
database. It proves typed retryable 503 and dependency-sensitive readiness while
liveness remains healthy. It must never be used to stop a shared database.
Malformed retained workflow history is deliberately qualified by the server's
native public-journal fixture; no HTTP endpoint can manufacture that corruption.

For the complete isolated build/provision/start/read/write/worker/outage lifecycle,
run `nix develop --no-write-lock-file -c just hurl` from the repository root. The
higher-level `tests/hurl/run.sh` builds the real executables, provisions its own
PostgreSQL, starts the source-owned fixture, supplies temporary credentials as
Hurl secrets, explicitly opts into writes/perimeter/outage, checks CLI stdin
replay and terminal waits, and tears down all owned resources on either outcome.
It invokes `hurlfmt --check` before execution. No developer database, ambient
target URL, live provider or unrecorded global tool is used.
