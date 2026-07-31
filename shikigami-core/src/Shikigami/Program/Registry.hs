-- | The program registry: the catalog of typed @shikumi@ programs shikigami can run
-- through @handan@, plus a name lookup. For this plan the only entry is a
-- deterministic, key-free @noop-summary@ task whose program is a @shikumi@ 'Embed'
-- node that returns a fixed JSON value and issues NO model call (EP-6 swaps it for a
-- real @Predict@ program). Mirrors @Handan.Registry@.
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
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Handan.Contract (Envelope (..), Kind (Effect), Status (ErrorS, Ok))
import Handan.Runtime (runProgramWith)
import Handan.Task (EvalHandle, Task (..), TaskKind (KEffect))
import Shikumi.Program (Program, embed)

-- | Every program shikigami knows about. EP-6's detectors append their tasks here;
-- for this plan it is just the deterministic stub.
programRegistry :: [Task]
programRegistry = [noopSummaryTask, webResearcherTask, codeResearcherTask]

-- | Find a task by its declared name.
lookupTask :: Text -> Maybe Task
lookupTask nm = List.find matches programRegistry
  where
    matches (Task {taskName = n}) = n == nm

-- | The @noop-summary@ program: a @shikumi@ 'Embed' node that returns a fixed
-- JSON digest with its input echoed back. Because the 'Embed' body just @pure@s a
-- value it runs under handan's interpreter with no @LLM@ call, so the program arm
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

-- | The deterministic stub task. @taskRun@ runs the embedded program through the
-- handan @Runtime@ (proving the handan path end to end) while staying key-free; its
-- @verdict@ carries the program's output JSON.
noopSummaryTask :: Task
noopSummaryTask =
  Task
    { taskName = "noop-summary",
      taskKind = KEffect,
      taskSummary = "Deterministic stub: returns a fixed JSON digest, no model call.",
      -- Reads the trigger payload the behavior runner puts under @payload@.
      -- A task is free to ignore the key (the two research stubs below do);
      -- this one reads it so the program arm's input is visible in its output.
      taskParse = \args -> Right (maybe Aeson.Null decodeOrString (Map.lookup "payload" args)),
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

-- | An argument-map value back to JSON. handan's 'ArgMap' is @Map Text Text@, so
-- a structured argument travels as its compact encoding; anything that does not
-- decode is kept verbatim as a JSON string rather than silently becoming @null@.
decodeOrString :: Text -> Value
decodeOrString raw =
  case Aeson.decodeStrict (TE.encodeUtf8 raw) of
    Just value -> value
    Nothing -> Aeson.String raw

webResearcherTask :: Task
webResearcherTask =
  fixedFindingTask
    webResearcherTaskName
    "Stub web specialist: returns a fixed external research finding."
    "Web sources indicate durable workflow delegation should journal child waits."

codeResearcherTask :: Task
codeResearcherTask =
  fixedFindingTask
    codeResearcherTaskName
    "Stub code specialist: returns a fixed implementation finding."
    "The code path should spawn child workflows before awaiting their results."

fixedFindingTask :: Text -> Text -> Text -> Task
fixedFindingTask taskName taskSummary finding =
  Task
    { taskName,
      taskKind = KEffect,
      taskSummary,
      taskParse = \_args -> Right (Aeson.Null :: Value),
      taskRun = \_rt _input ->
        pure
          Envelope
            { program = taskName,
              kind = Effect,
              status = Ok,
              verdict =
                Just
                  ( object
                      [ "agent" .= taskName,
                        "finding" .= finding
                      ]
                  ),
              artifacts = [],
              trace = Nothing,
              message = taskName <> " ok"
            },
      taskEval = Nothing :: Maybe (EvalHandle Value Value)
    }
