# 0040. Response options and foreground launches have separate authority

Date: 2026-10-06

Status: accepted

## Context

Baikai exposes HTTP Responses, batch coding CLI responses, attended terminal
launches and unattended named coding jobs. Their return values and permission
boundaries differ. A coding CLI returning text does not establish that its native
tools were disabled, or that cancelling its parent terminated descendants.

## Decision

Settei resolves Shikigami response settings and matching opaque HTTP credentials.
One shared builder dispatches through public Baikai handlers. A pure check names
unsupported model/options/context requirements immediately before every request;
no adapter may silently drop a requirement. Exact pinned-profile admission remains
separate and is derived from the actual model/options, including the configured
HTTP URL scheme. Plaintext overrides cannot inherit an HTTPS-only tuple. Catalog limits and endpoint
configuration are not proof of the remote served-model identity.

Foreground launches live in the light agent package and return process exits.
Interactive configuration requires explicit vendor safety and a terminal; model
omission visibly means vendor default. Unattended commands mount the whole public
Baikai parser, including its `agent` group, and preserve its loader, operator
ceiling, bounded runner, output discipline and exit codes. They create no durable
Response, memory session, sink receipt or authorization exception.

A batch adapter must prove descendant cancellation and reporter confinement in
its owning released package before becoming a background response choice. The
selected release fails the descendant contract, so CLI responses are unavailable.
Shikigami does not copy the owning process engine or infer confinement from the
absence of advertised Shikumi tool support. Foreground launch authority does not
supply background reporter authority.

## Alternatives rejected

Reusing a terminal/process result as `run-behavior-v2` success would confuse coding
workspace changes with durable model responses. Copying Baikai's parser or runner
would create a second loader, ceiling and supervision contract. Accepting an
unsupported option and hoping the vendor honors it would conceal a weaker request.

## Consequences

HTTP and foreground surfaces can ship independently of batch promotion. New Baikai
fields require an explicit setting owner or a recorded inapplicability reason.
Response configuration stays process-local; promotion must drain older work or
retain its prior configured worker. Pure guards introduce no workflow step or
serialized result change. Login/provider availability remains outside readiness.

## References

- [Plan 80](../plans/80-configure-model-providers-and-agent-launches-through-baikai.md)
- [Contract inventory](../evidence/baikai-execution/contracts.md)
- [Execution runbook](../operations/baikai-execution.md)
- [ADR 0007](0007-a-resolved-profile-is-a-run-local-policy-snapshot.md)
- [ADR 0021](0021-operator-verbs-wrap-the-owning-library.md)
- `mori://shinzui/baikai/packages/baikai-agent`
