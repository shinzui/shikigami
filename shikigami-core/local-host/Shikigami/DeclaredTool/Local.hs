-- | The local runner of declared-tool steps (EP-3 M4 of MasterPlan 22).
--
-- Admission decides the call against the declaration (a declared pattern
-- must match) and the run's authority (@UseCapability@ on @cli.<name>@), and
-- fixes the deadline in the run's worktree. The attempt runs through the
-- restart-safe machinery of "Shikigami.Process.Local": the launched program is
-- @shikigami-local tool-attempt@, which runs the declared command with no
-- shell in its own process group under the deadline and output bound, keeps
-- its output in the attempt directory and prints the result when it ends. A
-- restarted run collects that result or reattaches; it never runs the command
-- twice.
module Shikigami.DeclaredTool.Local
  ( localDeclaredToolRunner,
    ToolAttemptResult (..),
  )
where

import Data.Aeson (FromJSON, ToJSON, Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.Char (isAlphaNum)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (addUTCTime, diffUTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Keiro.Workflow (WorkflowId (..))
import Numeric.Natural (Natural)
import Shikigami.Agent.DeclarationValue (declarationCoordinateText)
import Shikigami.Authority (Authority (..), invokeToolAction)
import Shikigami.Capability.Declared
import Shikigami.Capability.Declared.Local (cliToolDescriptor)
import Shikigami.Capability.Overlay (CapabilityDescriptor (..), capabilityRevisionText)
import Shikigami.DeclaredTool.Workflow
import Shikigami.Process.Attempt (AttemptResult (..))
import Shikigami.Process.Local (AttemptCommand (..), quietHooks, runAttempt)
import Shikigami.Record (ActionRecord (..), RecordEvent (..), mkRecordEntry, mkRecordKind)
import Shikigami.Trust.LocalOperator.Approvals (programPathText, resolveProgram)
import Shikigami.Workspace.Launch (worktreeRootPath)
import Shikigami.Workspace.Local.Adapters (LocalWorkspace (..))
import Shikigami.Workspace.Local.Worktree (RunWorktree (..), openRunWorktree, renderWorktreeError)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

-- | What @shikigami-local tool-attempt@ prints when the command ends.
data ToolAttemptResult = ToolAttemptResult
  { exitCode :: !(Maybe Int),
    timedOut :: !Bool,
    droppedBytes :: !Natural,
    elapsedMs :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Per-stream bytes kept in the outcome. A rendered Seihou migration chain
-- (EP-7) is about 64 KiB, and playbooks quote tool output in later prompts.
keptOutput :: Natural
keptOutput = 262144

localDeclaredToolRunner :: FilePath -> LocalWorkspace -> DeclaredToolRunner
localDeclaredToolRunner wrapper local =
  DeclaredToolRunner
    { admit = admitStep local,
      attempt = \admission ->
        runAttempt
          admission.attemptDirectory
          admission.deadline
          (\bytes -> Aeson.toJSON <$> (Aeson.decodeStrict bytes :: Maybe ToolAttemptResult))
          quietHooks
          ( do
              now <- getCurrentTime
              let remaining = max 1 (ceiling (diffUTCTime admission.deadline now) :: Integer)
              pure
                AttemptCommand
                  { program = wrapper,
                    arguments =
                      [ "tool-attempt",
                        "--deadline-seconds",
                        Text.pack (show remaining),
                        "--output-limit",
                        Text.pack (show admission.outputLimit),
                        "--stdout",
                        Text.pack (admission.attemptDirectory </> "stdout.log"),
                        "--stderr",
                        Text.pack (admission.attemptDirectory </> "stderr-tool.log"),
                        "--",
                        Text.pack admission.program
                      ]
                        <> admission.arguments,
                    workingDirectory = admission.root
                  }
          ),
      settle = settleStep local
    }

admitStep :: LocalWorkspace -> DeclaredToolStepInput -> IO (Either ToolStepOutcome DeclaredToolAdmission)
admitStep local input@DeclaredToolStepInput {parent, step = requested, tools} =
  case find (\tool -> tool.name == requested.tool) (cliTools tools) of
    Nothing -> pure (Left (ToolRefused ("tool " <> toolNameText requested.tool <> " is not declared")))
    Just tool -> case decideCliArguments tool requested.arguments of
      Left refusal -> pure (Left (ToolRefused (renderCliRefusal refusal)))
      Right () ->
        resolveProgram (executableRefText tool.executable) >>= \case
          Nothing -> pure (Left (ToolFailed ("the executable " <> executableRefText tool.executable <> " is not found")))
          Just program -> do
            let descriptor = cliToolDescriptor tool program
            decided <- case invokeToolAction (cliCapabilityName tool.name) (capabilityRevisionText descriptor.revision) "run" of
              Left problem -> pure (Left problem)
              Right action -> either (const (Left ("the operator did not grant " <> cliCapabilityName tool.name))) (const (Right ())) <$> local.authority.decide local.principal action
            case decided of
              Left problem -> pure (Left (ToolRefused problem))
              Right () ->
                openRunWorktree local.stateDirectory local.agent (WorkflowId parent) local.repository >>= \case
                  Left problem -> pure (Left (ToolFailed (renderWorktreeError problem)))
                  Right worktree -> do
                    now <- getCurrentTime
                    let child = (declaredToolStepWorkflowId input).unWorkflowId
                        directory = local.stateDirectory </> "attempts" </> Text.unpack (Text.map (\c -> if isAlphaNum c || c == '-' then c else '_') child)
                    createDirectoryIfMissing True directory
                    pure
                      ( Right
                          DeclaredToolAdmission
                            { child,
                              tool = cliCapabilityName tool.name,
                              program = Text.unpack (programPathText program),
                              arguments = requested.arguments,
                              root = worktreeRootPath worktree.root,
                              deadline = addUTCTime (fromIntegral (requested.deadlineMinutes * 60)) now,
                              outputLimit = keptOutput,
                              attemptDirectory = directory
                            }
                      )

settleStep :: LocalWorkspace -> DeclaredToolAdmission -> AttemptResult Value -> IO ToolStepOutcome
settleStep local admission result = do
  outcome <- case result of
    NotLaunched detail -> pure (ToolFailed detail)
    GaveUp reason -> pure (ToolUncertain reason)
    Collected value -> case Aeson.fromJSON value of
      Aeson.Error problem -> pure (ToolFailed ("unreadable attempt result: " <> Text.pack problem))
      Aeson.Success ToolAttemptResult {exitCode, timedOut, droppedBytes, elapsedMs} -> do
        stdout <- kept (admission.attemptDirectory </> "stdout.log")
        stderr <- kept (admission.attemptDirectory </> "stderr-tool.log")
        let run = ToolRun {exit = maybe (-1) id exitCode, stdout, stderr, droppedBytes, elapsedMs}
        pure (if timedOut then ToolTimedOut run else ToolCompleted run)
  at <- getCurrentTime
  case mkRecordKind "tool.called" of
    Right kind
      | Right entry <-
          mkRecordEntry
            kind
            ( object
                [ "decision" .= ("admitted" :: Text),
                  "tool" .= admission.tool,
                  "host" .= ("step" :: Text),
                  "arguments" .= admission.arguments,
                  "outcome" .= toolStepOutcomeLabel outcome,
                  "exitCode" .= case outcome of ToolCompleted ToolRun {exit} -> Just exit; _ -> Nothing,
                  "child" .= admission.child
                ]
            ) ->
          () <$ local.record.append RecordEvent {at, run = Just (WorkflowId (fst (Text.breakOn ":declared-tool:" admission.child))), principal = declarationCoordinateText local.principal, tier = local.tier, agent = Just local.agent, entry}
    _ -> pure ()
  pure outcome
  where
    kept path = do
      exists <- doesFileExist path
      if exists then Text.Encoding.decodeUtf8Lenient . ByteString.take (fromIntegral keptOutput) <$> ByteString.readFile path else pure ""
