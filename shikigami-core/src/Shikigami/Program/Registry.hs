-- | The deterministic behavior task catalog, executed directly through Shikumi.
module Shikigami.Program.Registry
  ( programRegistry,
    lookupTask,
    researchSupervisorTaskName,
    webResearcherTaskName,
    codeResearcherTaskName,
    noopSummaryTask,
    noopSummaryProgram,
    noopBody,
    noopBodyWith,
    webResearcherTask,
    codeResearcherTask,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as Text
import Shikigami.Behavior.Error (RunError (ProgramRuntimeFailed))
import Shikigami.Behavior.Input (BehaviorInput (..))
import Shikigami.Program.Runtime (runProgramWith)
import Shikigami.Program.Task (ProgramTask (..))
import Shikumi.Program (Program, embed)

-- | Every program shikigami knows about. EP-6's detectors append their tasks here;
-- for this plan it is just the deterministic stub.
programRegistry :: [ProgramTask]
programRegistry = [noopSummaryTask, webResearcherTask, codeResearcherTask]

-- | Find a task by its declared name.
lookupTask :: Text -> Maybe ProgramTask
lookupTask nm = List.find matches programRegistry
  where
    matches (ProgramTask {name = n}) = n == nm

-- | The @noop-summary@ program: a @shikumi@ 'Embed' node that returns a fixed
-- JSON digest with its input echoed back. Because the 'Embed' body just @pure@s a
-- value it runs under the local interpreter with no @LLM@ call, so the program arm
-- is provable with no API key.
--
-- Echoing the input is what makes the program arm's de-stubbing observable: the
-- @input@ field was absent no matter what payload triggered the run, because the
-- runner handed every task an empty argument map.
noopSummaryProgram :: Program Value Value
noopSummaryProgram = embed (pure . noopBodyWith)

-- | The fixed digest the stub program produces for a program handed nothing.
noopBody :: Value
noopBody = noopBodyWith Aeson.Null

-- | The fixed digest, carrying whatever the program was given.
noopBodyWith :: Value -> Value
noopBodyWith input =
  object
    [ "summary" .= ("noop-summary produced a fixed digest" :: Text),
      "verb" .= ("heartbeat.tick" :: Text),
      "input" .= input
    ]

researchSupervisorTaskName :: Text
researchSupervisorTaskName = "research-supervisor"

webResearcherTaskName :: Text
webResearcherTaskName = "web-researcher"

codeResearcherTaskName :: Text
codeResearcherTaskName = "code-researcher"

-- | Run the embedded program without making a model call.
noopSummaryTask :: ProgramTask
noopSummaryTask =
  ProgramTask
    { name = "noop-summary",
      parse = \BehaviorInput {payload} -> Right payload,
      run = \rt input -> do
        result <- runProgramWith rt noopSummaryProgram input
        pure $ case result of
          Left err -> Left (ProgramRuntimeFailed (Text.pack (show err)))
          Right value -> Right value
    }

webResearcherTask :: ProgramTask
webResearcherTask =
  fixedFindingTask
    webResearcherTaskName
    "Web sources indicate durable workflow delegation should journal child waits."

codeResearcherTask :: ProgramTask
codeResearcherTask =
  fixedFindingTask
    codeResearcherTaskName
    "The code path should spawn child workflows before awaiting their results."

fixedFindingTask :: Text -> Text -> ProgramTask
fixedFindingTask taskName finding =
  ProgramTask
    { name = taskName,
      parse = \_ -> Right (),
      run = \_rt () ->
        pure (Right (object ["agent" .= taskName, "finding" .= finding]))
    }
