-- | The program registry: the catalog of typed @shikumi@ programs shikigami can run
-- through @handan@, plus a name lookup. For this plan the only entry is a
-- deterministic, key-free @noop-summary@ task whose program is a @shikumi@ 'Embed'
-- node that returns a fixed JSON value and issues NO model call (EP-6 swaps it for a
-- real @Predict@ program). Mirrors @Handan.Registry@.
module Shikigami.Program.Registry
  ( programRegistry,
    lookupTask,
    noopSummaryTask,
    noopSummaryProgram,
    noopBody,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as Text
import Handan.Contract (Envelope (..), Kind (Effect), Status (ErrorS, Ok))
import Handan.Runtime (runProgramWith)
import Handan.Task (EvalHandle, Task (..), TaskKind (KEffect))
import Shikumi.Program (Program, embed)

-- | Every program shikigami knows about. EP-6's detectors append their tasks here;
-- for this plan it is just the deterministic stub.
programRegistry :: [Task]
programRegistry = [noopSummaryTask]

-- | Find a task by its declared name.
lookupTask :: Text -> Maybe Task
lookupTask nm = List.find matches programRegistry
  where
    matches (Task {taskName = n}) = n == nm

-- | The @noop-summary@ program: a @shikumi@ 'Embed' node that ignores its input and
-- returns a fixed JSON value. Because the 'Embed' body just @pure@s a value it runs
-- under handan's interpreter with no @LLM@ call, so the program arm is provable with
-- no API key.
noopSummaryProgram :: Program Value Value
noopSummaryProgram = embed (\_input -> pure noopBody)

-- | The fixed digest the stub program produces.
noopBody :: Value
noopBody =
  object
    [ "summary" .= ("noop-summary produced a fixed digest" :: Text),
      "verb" .= ("heartbeat.tick" :: Text)
    ]

-- | The deterministic stub task. @taskRun@ runs the embedded program through the
-- handan @Runtime@ (proving the handan path end to end) while staying key-free; its
-- @verdict@ carries the program's output JSON.
noopSummaryTask :: Task
noopSummaryTask =
  Task
    { taskName = "noop-summary",
      taskKind = KEffect,
      taskSummary = "Deterministic stub: returns a fixed JSON digest, no model call.",
      taskParse = \_args -> Right (Aeson.Null :: Value),
      taskRun = \rt input -> do
        result <- runProgramWith rt noopSummaryProgram input
        pure $ case result of
          Left err ->
            Envelope
              { program = "noop-summary",
                kind = Effect,
                status = ErrorS,
                verdict = Nothing,
                artifacts = [],
                trace = Nothing,
                message = Text.pack (show err)
              }
          Right v ->
            Envelope
              { program = "noop-summary",
                kind = Effect,
                status = Ok,
                verdict = Just v,
                artifacts = [],
                trace = Nothing,
                message = "noop-summary ok"
              },
      taskEval = Nothing :: Maybe (EvalHandle Value Value)
    }
