-- | The initiative pack: an agent that reads what a stream already carries,
-- notices work nobody asked for and proposes it. It starts nothing without a
-- person or a standing policy an operator installed.
--
-- The pack contributes everything the use case is: the @propose-work@ flow
-- and its interpreter, the assessment decision program, the @initiatives@
-- setting, the stream hook that decides which observed records are worth an
-- evaluation, and the @proposals@ operator verbs. A distribution composes it;
-- the stock executables have none of it.
module FlowPack.Initiative
  ( initiativePack,
  )
where

import FlowPack.Initiative.Command (proposalsVerb)
import FlowPack.Initiative.Intake (streamDisposition)
import FlowPack.Initiative.Program.Assessment (assessmentProgram)
import FlowPack.Initiative.Runtime (proposeWorkFlow)
import FlowPack.Initiative.Setting (initiativeSettingsFrom, initiativesSetting)
import Shikigami.Flow.Sdk
import Shikigami.Flow.Sdk.Program
import Shikigami.Pack.Sdk (StreamHook (..))

initiativePack :: FlowPack
initiativePack =
  FlowPack
    { name = either (error . show) id (parseFlowPackName "initiative"),
      flows = [proposeWorkFlow],
      decisionPrograms = [SomeProgram assessmentProgram],
      retainedCodecs = [retainedCodec assessmentProgram],
      tasks = [],
      settings = [initiativesSetting],
      -- Pure and total: the verdict and the ledger transactions the stream
      -- consumer commits for it.
      triggers = noTriggerHooks {stream = Just (StreamHook (streamDisposition . initiativeSettingsFrom))},
      adminVerbs = [proposalsVerb],
      gauges = [],
      authorities = [],
      outputs = [],
      approvalChannels = [],
      trackerProviders = [],
      conversationChannels = []
    }
