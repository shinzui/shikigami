{-# LANGUAGE DataKinds #-}

-- | The practice-review pack: the architecture-practice router and the
-- OpenTelemetry specialist review it delegates to.
--
-- A distribution passes 'practiceReviewPack' to a role's @...With@ entry
-- point. That executable then runs agents whose manifests name these flows
-- and accepts the pack's setting; the stock executables, which compose no
-- pack, refuse both.
--
-- The review flow is the pack's one flow with capabilities of its own. Its
-- body ("FlowPack.PracticeReview.Body.OpenTelemetryReview") cannot name 'IOE'
-- or the store; 'interpretReview' is the reviewed IO surface, and every
-- result it produces crosses a @practice-review-*@ journal step first.
module FlowPack.PracticeReview
  ( practiceReviewPack,
    practiceReviewPackWith,
    routerDefinition,
    reviewDefinition,
    interpretReview,
  )
where

import FlowPack.PracticeReview.Attention (PracticeReviewAttentionEnv (..), runPracticeReviewAttentionAtomic)
import FlowPack.PracticeReview.Body.OpenTelemetryReview
  ( opentelemetryPracticeReviewFlow,
    opentelemetryPracticeReviewFlowName,
    opentelemetryPracticeReviewMermaid,
  )
import FlowPack.PracticeReview.Body.Router (architecturePracticeRouterFlow)
import FlowPack.PracticeReview.Capability
  ( ExecutionContext,
    PracticeReviewAttention,
    PracticeReviewEvaluator,
    PracticeReviewEvidence,
    PracticeReviewExecutionContext (..),
  )
import FlowPack.PracticeReview.Memory (PracticeReviewMemory)
import FlowPack.PracticeReview.Memory.Store (PracticeReviewMemoryEnv (..), runPracticeReviewMemory)
import FlowPack.PracticeReview.Runtime
import FlowPack.PracticeReview.Settings (attentionRecipientsFrom, attentionRecipientsSetting)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Flow.Sdk
import Shikigami.Pack.Sdk

-- | The pack as a distribution composes it. Evidence acquisition fails closed
-- until the Kikan content plane exists
-- (@mori:\/\/shinzui\/kikan\/okf\/improvement-requests\/concepts\/IR-5@), so a
-- review of a real repository ends @unresolved@ with a recorded
-- @content-plane-unavailable@ problem. Attention recipients come from the
-- pack's setting.
practiceReviewPack :: FlowPack
practiceReviewPack = practiceReviewPackWith failClosedPracticeReviewRuntime

-- | The pack over a given runtime: a test supplies an evidence reader, an
-- evaluator and a fixed recipient map.
practiceReviewPackWith :: PracticeReviewRuntime -> FlowPack
practiceReviewPackWith runtime =
  FlowPack
    { name = either (error . show) id (parseFlowPackName "practice-review"),
      flows =
        [ kernelCapabilityFlow routerDefinition architecturePracticeRouterFlow,
          PackFlow {definition = reviewDefinition, run = \context -> interpretReview runtime context . opentelemetryPracticeReviewFlow}
        ],
      decisionPrograms = [],
      retainedCodecs = [],
      tasks = [],
      settings = [attentionRecipientsSetting],
      triggers = noTriggerHooks,
      adminVerbs = []
    }

routerDefinition :: FlowDef
routerDefinition =
  FlowDef
    { name = declarationCoordinate "architecture-practice-router",
      lifecycle = LifecycleDiagram {mermaid = "flowchart LR\n  Input --> Router --> Specialist", validationWarnings = []},
      decisionSlots = [],
      requiresDefaultModel = DefaultModelRequired,
      decisionMode = StrictDecisions
    }

reviewDefinition :: FlowDef
reviewDefinition =
  FlowDef
    { name = declarationCoordinate opentelemetryPracticeReviewFlowName,
      lifecycle = LifecycleDiagram {mermaid = opentelemetryPracticeReviewMermaid, validationWarnings = []},
      decisionSlots = [],
      requiresDefaultModel = DefaultModelRequired,
      decisionMode = StrictDecisions
    }

-- | Install the pack's five interpreters around a review body, in the order
-- the kernel installed them before the flow moved: the execution context
-- outermost, attention innermost.
interpretReview ::
  (Workflow :> es, IOE :> es, Store :> es) =>
  PracticeReviewRuntime ->
  FlowRunContext ->
  Eff (PracticeReviewAttention : PracticeReviewMemory : PracticeReviewEvaluator : PracticeReviewEvidence : ExecutionContext : es) a ->
  Eff es a
interpretReview runtime context =
  runExecutionContext executionContextOfRun
    . runPracticeReviewEvidence True runtime
    . runPracticeReviewEvaluator True context.model runtime
    . runPracticeReviewMemory memoryEnv
    . runPracticeReviewAttentionAtomic attentionEnv
  where
    executionContextOfRun =
      PracticeReviewExecutionContext
        { identity = context.requestIdentity,
          parentWorkflowId = context.parentRunId,
          parentSessionId = context.parentSession,
          childWorkflowId = context.runId,
          childSessionId = context.session
        }
    memoryEnv =
      PracticeReviewMemoryEnv
        { appEnv = context.app,
          agent = context.agent,
          identity = context.identity,
          sessionId = Just context.session
        }
    attentionEnv =
      PracticeReviewAttentionEnv
        { agent = context.agent.name,
          identity = context.requestIdentity,
          runId = context.session,
          occurredAt = Just context.occurredAt,
          activity = Just context.activity,
          grants = context.grants,
          directory = context.directory,
          recipients = case runtime.attentionRecipients of
            FixedRecipients fixed -> fixed
            RecipientsFromSettings -> attentionRecipientsFrom context.settings
        }
