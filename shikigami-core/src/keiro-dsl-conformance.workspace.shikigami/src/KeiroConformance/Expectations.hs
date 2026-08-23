-- Created once by keiro-dsl. This module is application-owned; review and edit it to accept conformance changes.
module KeiroConformance.Expectations (expectedServiceConformanceFacts) where

expectedServiceConformanceFacts :: [(String, String)]
expectedServiceConformanceFacts =
  [ ("workflow/AgentRun/awaits", "[\"await-ack\"]"),
    ("workflow/AgentRun/body", "[\"step:ingest-job\",\"step:lookup-agent\",\"patch:shikigami-resolve-profile-v1(step:resolve-profile)\",\"patch:shikigami-capability-overlays-v1(step:resolve-capability-overlays)\",\"step:open-session\",\"step:recall\",\"step:run-behavior\",\"patch:shikigami-behavior-retry-v1(step:run-behavior-v2)\",\"step:classify\",\"await:await-ack\",\"step:route-catalog-architecture-practice\",\"step:route-decision-architecture-practice\",\"patch:shikigami-flow-memory-steps-v1(step:recall-risk-history,step:remember-acknowledged,step:remember-declined,step:remember-escalated)\",\"patch:shikigami-emit-signal-labels-v1()\",\"step:dispatch-sinks\",\"step:fail-session\",\"step:record\",\"step:complete\",\"child:delegate\"]"),
    ("workflow/AgentRun/idField", "idempotencyKey"),
    ("workflow/AgentRun/idVia", "idText"),
    ("workflow/AgentRun/name", "shikigami.agent-run"),
    ("workflow/AgentRun/patches", "[\"shikigami-resolve-profile-v1\",\"shikigami-capability-overlays-v1\",\"shikigami-behavior-retry-v1\",\"shikigami-flow-memory-steps-v1\",\"shikigami-emit-signal-labels-v1\"]"),
    ("workflow/DanwaConversation/awaits", "[\"next-message\"]"),
    ("workflow/DanwaConversation/body", "[\"step:ingest-start\",\"step:lookup-agent\",\"step:resolve-session\",\"patch:shikigami-behavior-retry-v1()\",\"patch:shikigami-conversation-rotation-v1(step:record-user,step:run-behavior-v2,step:record-assistant-and-reply,step:turn-result,await:next-message,step:idle-timeout)\",\"continueAsNew:ConversationSeed\"]"),
    ("workflow/DanwaConversation/idField", "input"),
    ("workflow/DanwaConversation/idVia", "conversationWorkflowId"),
    ("workflow/DanwaConversation/name", "shikigami.danwa-conversation"),
    ("workflow/DanwaConversation/patches", "[\"shikigami-behavior-retry-v1\",\"shikigami-conversation-rotation-v1\"]")
  ]
