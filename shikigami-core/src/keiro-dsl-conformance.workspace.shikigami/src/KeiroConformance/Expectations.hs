-- Created once by keiro-dsl. This module is application-owned; review and edit it to accept conformance changes.
module KeiroConformance.Expectations (expectedServiceConformanceFacts) where

expectedServiceConformanceFacts :: [(String, String)]
expectedServiceConformanceFacts =
  [ ("workflow/AgentRun/awaits", "[]"),
    ("workflow/AgentRun/body", "[\"step:ingest-job\",\"patch:shikigami-execution-resources-v1(step:validate-execution-root)\",\"step:lookup-agent\",\"step:resolve-profile\",\"step:resolve-capability-overlays\",\"step:resolve-approval-policy\",\"step:open-session\",\"step:recall\",\"step:run-behavior-v2\",\"step:classify\",\"child:approval\",\"patch:shikigami-flow-decisions-v1(step:decision-policy,step:decision-prepare-triage,step:decision-result-triage,step:decision-catalog-investigate,step:decision-prepare-investigate,step:decision-result-investigate)\",\"step:route-catalog-architecture-practice\",\"step:route-decision-architecture-practice\",\"step:recall-risk-history\",\"step:remember-acknowledged\",\"step:remember-declined\",\"step:remember-escalated\",\"step:practice-review-remember-provisional\",\"step:practice-review-resolve\",\"step:practice-review-recall\",\"step:practice-review-chain\",\"step:practice-review-evidence\",\"step:practice-review-evaluate\",\"step:practice-review-attention\",\"step:dispatch-sinks\",\"step:fail-session\",\"step:record\",\"step:complete\",\"child:delegate\"]"),
    ("workflow/AgentRun/idField", "input"),
    ("workflow/AgentRun/idVia", "runJobWorkflowId"),
    ("workflow/AgentRun/name", "shikigami.agent-run"),
    ("workflow/AgentRun/patches", "[\"shikigami-execution-resources-v1\",\"shikigami-flow-decisions-v1\"]"),
    ("workflow/Approval/awaits", "[\"decision\"]"),
    ("workflow/Approval/body", "[\"step:ingest-approval\",\"step:notify\",\"await:decision\"]"),
    ("workflow/Approval/idField", "reviewRequestId"),
    ("workflow/Approval/idVia", "reviewRequestIdText"),
    ("workflow/Approval/name", "shikigami.approval"),
    ("workflow/Approval/patches", "[]"),
    ("workflow/DanwaConversation/awaits", "[\"next-message\"]"),
    ("workflow/DanwaConversation/body", "[\"step:ingest-start\",\"step:lookup-agent\",\"step:resolve-session\",\"step:record-user\",\"step:run-behavior-v2\",\"step:record-assistant-and-reply\",\"step:turn-result\",\"await:next-message\",\"step:idle-timeout\",\"continueAsNew:ConversationSeed\"]"),
    ("workflow/DanwaConversation/idField", "input"),
    ("workflow/DanwaConversation/idVia", "conversationWorkflowId"),
    ("workflow/DanwaConversation/name", "shikigami.danwa-conversation"),
    ("workflow/DanwaConversation/patches", "[]")
  ]
