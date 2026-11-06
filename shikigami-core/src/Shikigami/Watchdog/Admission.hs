{-# LANGUAGE DataKinds #-}

-- | Schedule-only resource enrollment. Other trigger paths grant no allowance.
module Shikigami.Watchdog.Admission (watchdogAllowance, enrollScheduledWatchdogTx) where

import Control.Lens ((&), (.~))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime)
import Hasql.Transaction (Transaction)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Principal (AgentIdentity (..), resolveAgentIdentity)
import Shikigami.Agent.RunJob (RunJob (..), runJobWorkflowId)
import Shikigami.Duration (durationTime)
import Shikigami.Execution.Identity (ExecutionRootId)
import Shikigami.Execution.Resources (Envelope (..))
import Shikigami.Execution.ResourcesStore (recoverRootForWorkflowTx)
import Shikigami.Watchdog.Settings

watchdogAllowance :: Maybe WatchdogSettings -> AgentDecl -> AgentIdentity -> Either Text (Maybe WatchdogAllowance)
watchdogAllowance settings declaration identity = case declaration.behavior of
  Flow {name} | name == declarationCoordinate "watchdog-sweep" -> do
    configured <- maybe (Left "watchdog is disabled") Right settings
    allowance <- maybe (Left "watchdog allowance is missing") Right configured.allowance
    case identity of VerifiedIdentity _ -> pure (); _ -> Left "watchdog schedule requires a verified principal"
    if configured.principal == identity && VerifiedIdentity allowance.principal == identity && allowance.flow == name
      then Right (Just allowance)
      else Left "watchdog allowance principal or Flow mismatch"
  _ -> Right Nothing

enrollScheduledWatchdogTx :: ExecutionRootId -> WatchdogAllowance -> UTCTime -> RunJob -> Transaction (Either Text RunJob)
enrollScheduledWatchdogTx candidate allowance now job
  | job.identity /= VerifiedIdentity allowance.principal || allowance.flow /= declarationCoordinate "watchdog-sweep" || job.parentRunWorkflowId /= Nothing || job.parentSessionId /= Nothing || job.delegationBudgetId /= Nothing || job.delegationDepth /= Nothing || job.executionRootId /= Nothing = pure (Left "watchdog enrollment requires the bound new root run")
  | otherwise = case resolveAgentIdentity job.identity of
      Left _ -> pure (Left "watchdog identity is unresolved")
      Right creator -> do
        root <- recoverRootForWorkflowTx candidate creator job.agentName (runJobWorkflowId job) (Envelope allowance.limits (addUTCTime (durationTime allowance.cutoffSeconds) now))
        pure case root of
          Left _ -> Left "watchdog resource enrollment refused"
          Right identifier -> Right (job & #executionRootId .~ Just identifier)
