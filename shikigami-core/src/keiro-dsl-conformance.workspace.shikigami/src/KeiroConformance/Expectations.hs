-- Created once by keiro-dsl. This module is application-owned; review and edit it to accept conformance changes.
module KeiroConformance.Expectations (expectedServiceConformanceFacts) where

expectedServiceConformanceFacts :: [(String, String)]
expectedServiceConformanceFacts =
  [ ("workflow/AgentRun/awaits", "[\"await-ack\"]"),
    ("workflow/AgentRun/body", "[\"step:ingest-job\",\"step:lookup-agent\",\"step:open-session\",\"step:recall\",\"step:run-behavior\",\"step:classify\",\"await:await-ack\",\"patch:shikigami-emit-signal-labels-v1()\",\"step:dispatch-sinks\",\"step:fail-session\",\"step:record\",\"step:complete\",\"child:delegate\"]"),
    ("workflow/AgentRun/idField", "idempotencyKey"),
    ("workflow/AgentRun/idVia", "idText"),
    ("workflow/AgentRun/name", "shikigami.agent-run"),
    ("workflow/AgentRun/patches", "[\"shikigami-emit-signal-labels-v1\"]"),
    ("workflow/DanwaConversation/awaits", "[]"),
    ("workflow/DanwaConversation/body", "[\"step:ingest-start\",\"step:lookup-agent\",\"step:resolve-session\"]"),
    ("workflow/DanwaConversation/idField", "input"),
    ("workflow/DanwaConversation/idVia", "conversationWorkflowId"),
    ("workflow/DanwaConversation/name", "shikigami.danwa-conversation"),
    ("workflow/DanwaConversation/patches", "[]")
  ]
