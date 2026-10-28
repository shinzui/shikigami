# 0058. Conversation acceptance and wakes retain their generation

Date: 2026-10-28

Status: accepted

## Context

A conversation turn can outlive its ingress queue delivery while its execution
child awaits model, tool or approval work. Redelivery must observe that accepted
turn without using the wake reserved for the following message. Completed
awakeable repair must also preserve the generation that published the token.

## Decision

New eligible conversation Skills use the real
`shikigami-conversation-durable-execution-v1` branch. They freeze a protected
assignment and await the existing execution driver. Old journal populations
retain `run-behavior-v2`. Selection/profile and turn-result codecs remain stable;
the existing atomic assistant-turn/reply step still owns the reply. Conversations
admit only their existing base tool registry and refuse capability overlays.

Ingress distinguishes accepted input from a completed reply. It acknowledges
acceptance only from the matching recorded execution admission or next-message
wake, using bounded current/previous-generation reads. A duplicate current turn
observes its existing work. An unaccepted message retains queue backpressure;
this does not introduce the continuing-worker mailbox owned by plan 84.

Message and idle-timeout publication carry an explicit generation into one
transaction composing Keiro's public journal append and awakeable completion.
A completed token repairs only that generation. A competing completion cannot
replace its payload. New idle timer payloads include their generation; historical
payloads remain readable and require their token to match the live allocation.
Superseded timers are cancelled without appending to the successor journal.

New assignment contexts use replay format 2 with exactly one explicit current
request marker. Prior conversation turns remain chronological factual messages,
separate from the current request, and can be compacted independently. The request
survives context selection and summaries even after later model/tool messages.
Format 1 retains its original first-user anchor and encoding. Conversation
history is loaded only for new admission, excludes the just-recorded user turn,
and never invents provider continuation or usage from earlier assignments.

## Consequences

Long accepted turns no longer consume ingress retries merely while awaiting their
child. Parent replay reuses completed output after provider retirement and still
produces one atomic reply. Both real patch branches and historical timer/context
readers remain supported. Roll forward after activating this patch and drain old
resumers before admitting its new population. Operator/declaration policy wiring,
ephemeral execution and recovery-class qualification remain open in plan 83.

## References

- [Plan 83](../plans/83-recover-durable-model-and-tool-turns-with-composed-policies.md)
- [Workflow versioning](../workflow-versioning.md)
- [ADR 0055](0055-execution-drivers-rotate-around-accepted-work.md)
- [ADR 0057](0057-skill-parents-admit-frozen-assignments-and-await-execution-children.md)
- [FRIC-12](../friction-log/12-awakeable-repair-requires-an-explicit-publishing-generation-transaction.md)
