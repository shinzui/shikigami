{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}

module Shikigami.Flow
  ( FlowDef (..),
    FlowEffects,
    FlowRuntime (..),
    LifecycleDiagram (..),
    atRiskCustomerLifecycleDiagram,
    flowDeclarationErrors,
    flowRegistry,
    lookupFlow,
    registeredFlowNames,
  )
where

import Data.Aeson (Value)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Effectful (Eff, (:>))
import Keiro.Workflow (Workflow)
import Shikigami.Agent.Approval (ApprovalEnv)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Flow.Acknowledgement (Acknowledgement)
import Shikigami.Flow.AtRiskCustomer (atRiskCustomerFlow)
import Shikigami.Flow.Capability (Activity, Memory, Sink)
import Shikigami.Flow.Delegate (Delegate)
import Shikigami.Flow.Delegate qualified as Delegate
import Shikigami.Flow.Lifecycle.AtRiskCustomer (atRiskCustomerMermaid, atRiskCustomerValidationWarnings)

-- | Everything a flow body may do, and therefore everything it may not.
--
-- The absence of 'Effectful.IOE' and 'Kiroku.Store.Effect.Store' is the point of
-- this alias, not an oversight. A durable workflow replays its body, answering
-- journaled steps from the journal and re-running everything else; an effect
-- with an external footprint that is not wrapped in a step therefore happens an
-- unpredictable number of times. While a flow body could @liftIO@, nothing
-- prevented that, and no reviewer could prove a flow had not done it.
--
-- So every way a flow reaches the world is a capability with a replay-safe
-- interpreter: 'Memory' journals its recalls and writes, 'Sink' journals its
-- emissions, 'Acknowledgement' parks through the approval machinery, and
-- 'Activity' is pure data. 'Workflow' stays so a flow can still name a pure
-- checkpoint with 'Keiro.Workflow.step' — without 'IOE' that step body cannot
-- smuggle IO in.
--
-- Adding an effect here widens what every flow may do. Add a capability instead.
type FlowEffects es =
  (Workflow :> es, Memory :> es, Sink :> es, Activity :> es, Acknowledgement :> es, Delegate :> es)

-- | What 'Shikigami.Flow.Acknowledgement.runAcknowledgement' needs to interpret
-- a flow's parks.
--
-- This used to be threaded into the flow body itself, because
-- 'Shikigami.Flow.Acknowledgement.awaitAcknowledgement' was a direct call and
-- needed both values in scope where the flow made it. Now the interpreter holds
-- them, so a flow body closes over nothing and 'flowRegistry' is a plain list
-- rather than a function of deployment configuration.
data FlowRuntime = FlowRuntime
  { approval :: !ApprovalEnv,
    acknowledgementDeadline :: !NominalDiffTime
  }

data LifecycleDiagram = LifecycleDiagram
  { mermaid :: !Text,
    validationWarnings :: ![Text]
  }
  deriving stock (Eq, Show)

data FlowDef = FlowDef
  { name :: !Text,
    lifecycle :: !LifecycleDiagram,
    run :: forall es. (FlowEffects es) => Value -> Eff es Value
  }

instance Show FlowDef where
  show FlowDef {name} = "FlowDef {name = " <> show name <> "}"

atRiskCustomerLifecycleDiagram :: LifecycleDiagram
atRiskCustomerLifecycleDiagram =
  LifecycleDiagram
    { mermaid = atRiskCustomerMermaid,
      validationWarnings = Text.pack . show <$> atRiskCustomerValidationWarnings
    }

-- | Every flow this build registers. Add a flow here and nowhere else.
--
-- This is __one__ list, and 'registeredFlowNames' is a projection of it rather
-- than a second list beside it. A flow that were runnable but missing from the
-- name list would be rejected at boot despite working; one that were listed but
-- not registered would pass validation and then fail mid-run — the exact failure
-- 'registeredFlowNames' exists to close.
--
-- It is a plain value now. It used to be a function of a 'FlowRuntime', because
-- a flow body closed over the approval environment and the acknowledgement
-- deadline; a caller that only wanted to know a flow's /name/ or /diagram/ still
-- had to mint an approval environment to ask. Acknowledgement is a capability
-- now, so the body closes over nothing and the question is answerable directly.
flowRegistry :: [FlowDef]
flowRegistry =
  [ FlowDef
      { name = "at-risk-customer",
        lifecycle = atRiskCustomerLifecycleDiagram,
        run = atRiskCustomerFlow
      },
    FlowDef
      { name = "delegation-proof",
        lifecycle =
          LifecycleDiagram
            { mermaid = "flowchart LR\n  Supervisor --> WebResearcher",
              validationWarnings = []
            },
        run = delegationProofFlow
      }
  ]

-- | Minimal registered proof that Flow can reach the same governed child-run
-- machinery as an imperative supervisor. The target and call-site key are
-- static durable vocabulary; the triggering payload remains the child's input.
delegationProofFlow :: (FlowEffects es) => Value -> Eff es Value
delegationProofFlow payload = do
  child <- Delegate.delegate "web-researcher" "web-researcher" payload
  Delegate.awaitOne child

-- | The name of every registered flow.
--
-- This is what an agent manifest's @Behavior.Flow { name }@ must match. Before
-- it existed the only check happened inside a running workflow, so a typo in a
-- manifest became a failed agent run rather than a refused deployment.
registeredFlowNames :: [Text]
registeredFlowNames = [name | FlowDef {name} <- flowRegistry]

lookupFlow :: Text -> Maybe FlowDef
lookupFlow requested =
  find (\FlowDef {name} -> name == requested) flowRegistry

-- | Every declaration error in an agent's behavior that this build can decide
-- without running it, in declaration order. An empty list means the behavior is
-- deployable.
--
-- Today that is exactly one check: a @Behavior.Flow { name }@ naming a flow no
-- registration provides. It used to surface only from inside a running workflow
-- — @runFlowBehavior@ returns @Left \"unknown flow ...\"@ on a registry miss —
-- which means a typo in a manifest cost a failed agent run per trigger instead
-- of a refused deployment. Mirrors 'Shikigami.Sink.Validate.sinkDeclarationErrors'.
flowDeclarationErrors :: AgentDecl -> [Text]
flowDeclarationErrors AgentDecl {behavior} =
  case behavior of
    Flow {name = flowName}
      | flowName `notElem` registeredFlowNames ->
          [ "unknown flow "
              <> flowName
              <> "; registered flows: "
              <> Text.intercalate ", " registeredFlowNames
          ]
    _ -> []
