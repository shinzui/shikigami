{-# LANGUAGE DataKinds #-}

-- | The watchdog's say over its scheduled ticks. Other trigger paths grant no
-- allowance; the kernel enrolls the root ("Shikigami.Trigger.Enrollment").
module Shikigami.Watchdog.Admission (watchdogAllowance, watchdogScheduleHook) where

import Data.Text (Text)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Principal (AgentIdentity (..))
import Shikigami.Duration (durationTime)
import Shikigami.Trigger.Hook (ScheduleCandidate (..), ScheduleHook (..), ScheduledAllowance (..))
import Shikigami.Watchdog.Settings

-- | Every tick of a @watchdog-sweep@ agent needs the operator's allowance for
-- exactly its principal; a tick of any other flow has none and needs none.
watchdogScheduleHook :: ScheduleHook
watchdogScheduleHook = ScheduleHook \settings candidate ->
  fmap (fmap scheduled) (watchdogAllowance (watchdogSettingsFrom settings) candidate.agent candidate.identity)
  where
    scheduled allowance = ScheduledAllowance {principal = allowance.principal, limits = allowance.limits, lifetime = durationTime allowance.cutoffSeconds}

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
