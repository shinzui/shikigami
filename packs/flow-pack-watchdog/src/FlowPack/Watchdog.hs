-- | The watchdog as a flow pack: one advisory sweep per scheduled tick over
-- active work, read-only, with no authority to intervene (ADR-118).
--
-- The pack contributes the @watchdog-sweep@ flow and its drift assessment
-- program, the @watchdog@ setting, a schedule hook that funds each tick from
-- the operator's allowance (ADR-119), the @watchdog@ operator verbs and the
-- sweep-age gauge.
module FlowPack.Watchdog (watchdogPack) where

import FlowPack.Watchdog.Admission (watchdogScheduleHook)
import FlowPack.Watchdog.Command (watchdogVerb)
import FlowPack.Watchdog.Program.Drift (driftProgram)
import FlowPack.Watchdog.Runtime (sweepAgeGauge, watchdogSweepFlow)
import FlowPack.Watchdog.Setting (watchdogSetting)
import Shikigami.Flow.Sdk
import Shikigami.Flow.Sdk.Program

watchdogPack :: FlowPack
watchdogPack =
  FlowPack
    { name = either (error . show) id (parseFlowPackName "watchdog"),
      flows = [watchdogSweepFlow],
      decisionPrograms = [SomeProgram driftProgram],
      retainedCodecs = [retainedCodec driftProgram],
      tasks = [],
      settings = [watchdogSetting],
      triggers = noTriggerHooks {schedule = Just watchdogScheduleHook},
      adminVerbs = [watchdogVerb],
      gauges = [sweepAgeGauge],
      authorities = []
    }
