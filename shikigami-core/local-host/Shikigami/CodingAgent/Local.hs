-- | The local-operator coding-agent runner (EP-2 of MasterPlan 22).
--
-- A step runs a vendor coding tool through the mounted Baikai CLI
-- (@shikigami-agent-launch unattended agent run@) as a detached child in its
-- own session, with its JSON envelope and standard error redirected into a
-- per-attempt directory outside the worktree. That directory is the attempt's
-- recovery state: a restarted worker reads it, collects a finished result,
-- reattaches to a live launcher, or gives up as uncertain
-- ("Shikigami.Process.Attempt"). It never launches an attempt twice.
module Shikigami.CodingAgent.Local
  ( LocalCodingAgentConfig (..),
    localCodingAgentRunner,
    settleEnvelope,
    finalMessageOf,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM, forM_, void)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAlphaNum)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (addUTCTime, diffUTCTime, getCurrentTime)
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinateText)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.Authority (Action (LaunchCodingAgent), mkCodingAgentTarget)
import Shikigami.Capability.Declared (ToolDecl, cliTools, mcpRequests, renderCliToolDecl)
import Shikigami.Capability.Declared.Catalog (checkMcpRequests, defaultToolCatalogPath, loadToolCatalog, renderToolResolutionError)
import Shikigami.Capability.Declared.Gate (GatedTools (..), claudeHookSettings, claudeMcpConfig, codexMcpArguments)
import Shikigami.Capability.Mcp (McpToolRequest (..), mcpServerIdText, mcpToolNameText)
import Shikigami.CodingAgent.Types
import Shikigami.CodingAgent.Workflow (CodingAgentAdmission (..), CodingAgentRunner (..), CodingAgentStepInput (..), codingAgentStepWorkflowId)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Process.Attempt
import Shikigami.Process.Local
import Shikigami.Record (ActionRecord (..), RecordEvent (..), mkRecordEntry, mkRecordKind)
import Shikigami.Repository (repositoryIdText)
import Shikigami.Workspace.Launch (worktreeRootPath)
import Shikigami.Workspace.Local.Adapters (LocalWorkspace (..))
import Shikigami.Workspace.Local.Worktree (RunWorktree (..), gitIn, openRunWorktree, renderWorktreeError)
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))
import System.Process

data LocalCodingAgentConfig = LocalCodingAgentConfig
  { -- | The @shikigami-agent-launch@ executable that mounts Baikai's CLI.
    launcher :: !FilePath,
    -- | The @shikigami-local@ executable whose @gate@ command Claude Code's
    -- PreToolUse hook runs for each shell and MCP call (EP-3 M3).
    gate :: !FilePath
  }

localCodingAgentRunner :: LocalCodingAgentConfig -> LocalWorkspace -> CodingAgentRunner
localCodingAgentRunner config local =
  CodingAgentRunner
    { admit = admitStep config local,
      attempt = attemptStep config local,
      settle = settleStep local
    }

-- | Decide the launch, open the run's worktree, fix the absolute deadline,
-- and prepare the attempt directory with copies of the attached skills.
admitStep :: LocalCodingAgentConfig -> LocalWorkspace -> CodingAgentStepInput -> IO (Either FailureReason CodingAgentAdmission)
admitStep config local input@CodingAgentStepInput {parent, step = requested, tools} =
  case mkCodingAgentTarget (providerText requested.provider) (accessText requested.access) (repositoryIdText local.repository.identity) of
    Left problem -> pure (Left (WorkspaceUnavailable problem))
    Right target ->
      local.authority.decide local.principal (LaunchCodingAgent target) >>= \case
        Left _ -> pure (Left (TierRefused ("the operator did not grant a " <> providerText requested.provider <> " coding agent on " <> repositoryIdText local.repository.identity)))
        Right _ ->
          openRunWorktree local.stateDirectory local.agent (WorkflowId parent) local.repository >>= \case
            Left problem -> pure (Left (WorkspaceUnavailable (renderWorktreeError problem)))
            Right worktree -> do
              now <- getCurrentTime
              let child = (codingAgentStepWorkflowId input).unWorkflowId
                  directory = local.stateDirectory </> "attempts" </> Text.unpack (safeName child)
              createDirectoryIfMissing True directory
              copied <- copySkills directory requested.skills
              rendered <- renderTools config requested.provider (worktreeRootPath worktree.root) directory tools
              pure case (copied, rendered) of
                (Left problem, _) -> Left (WorkspaceUnavailable problem)
                (_, Left problem) -> Left (Misconfigured problem)
                (Right skills, Right (providerArgs, toolLines)) ->
                  Right
                    CodingAgentAdmission
                      { step = requested,
                        child,
                        repository = repositoryIdText worktree.repository,
                        root = worktreeRootPath worktree.root,
                        branch = worktree.branch,
                        base = worktree.base,
                        deadline = addUTCTime (fromIntegral (deadlineMinutesValue requested.deadlineMinutes * 60)) now,
                        attemptDirectory = directory,
                        skills,
                        providerArgs,
                        toolLines
                      }

-- | Render the declared tools into the attempt directory and the vendor's
-- arguments. Claude Code: a PreToolUse hook running the gate over
-- @tools.json@ for every shell and MCP call, and an MCP configuration of only
-- the requested servers. Codex: the requested MCP servers with only their
-- requested tools enabled; Codex cannot confine shell commands, so declared
-- CLI tools are refused for it.
renderTools :: LocalCodingAgentConfig -> CodingAgentProvider -> FilePath -> FilePath -> [ToolDecl] -> IO (Either Text ([Text], [Text]))
renderTools config provider root directory tools
  | null tools = pure (Right ([], []))
  | provider == Codex && not (null (cliTools tools)) = pure (Left "declared CLI tools cannot be confined for Codex; declare only MCP tools for a Codex step")
  | otherwise = do
      catalog <- loadToolCatalog =<< defaultToolCatalogPath
      case catalog >>= \loaded -> either (Left . renderToolResolutionError) Right (checkMcpRequests loaded (mcpRequests tools)) of
        Left problem -> pure (Left problem)
        Right servers -> do
          environment <- fmap (\(name, value) -> (Text.pack name, Text.pack value)) <$> getEnvironment
          let lines' = (renderCliToolDecl <$> cliTools tools) <> [mcpServerIdText request.server <> " (MCP): " <> Text.intercalate ", " (mcpToolNameText <$> foldr (:) [] request.tools) | request <- mcpRequests tools]
          case provider of
            Codex -> pure (Right (codexMcpArguments root servers, lines'))
            ClaudeCode -> do
              let toolsFile = directory </> "tools.json"
                  settingsFile = directory </> "settings.json"
                  mcpFile = directory </> "mcp.json"
                  gateCommand = "'" <> Text.pack config.gate <> "' gate '" <> Text.pack toolsFile <> "'"
              LazyByteString.writeFile toolsFile (Aeson.encode GatedTools {cli = cliTools tools, mcp = mcpRequests tools})
              LazyByteString.writeFile settingsFile (Aeson.encode (claudeHookSettings gateCommand))
              LazyByteString.writeFile mcpFile (Aeson.encode (claudeMcpConfig root environment (fst <$> servers)))
              pure (Right (["--settings", Text.pack settingsFile, "--strict-mcp-config", "--mcp-config", Text.pack mcpFile], lines'))

-- | Copy each attached skill directory (it must hold a @SKILL.md@; at most
-- eight, 2 MiB in all) into the attempt directory, so the agent reads a copy
-- and never the original.
copySkills :: FilePath -> [SkillDirectory] -> IO (Either Text [(Text, FilePath)])
copySkills directory requested
  | length requested > 8 = pure (Left "a coding-agent step attaches at most eight skills")
  | otherwise = do
      copies <- forM requested \skill -> do
        source <- makeAbsolute (skillDirectoryPath skill)
        hasSkill <- doesFileExist (source </> "SKILL.md")
        if not hasSkill
          then pure (Left ("skill directory " <> Text.pack source <> " has no SKILL.md"))
          else do
            let name = Text.pack (takeFileName source)
                target = directory </> "skills" </> Text.unpack name
            createDirectoryIfMissing True (directory </> "skills")
            (code, _, err) <- readProcessWithExitCode "cp" ["-R", "-P", source <> "/.", target] ""
            pure if code == ExitSuccess then Right (name, target) else Left ("copying skill " <> name <> " failed: " <> Text.pack err)
      pure (sequence copies)

-- | The coding agent's own files in its attempt directory, beside the
-- generic ones of "Shikigami.Process.Local".
data AgentFiles = AgentFiles {evidence :: !FilePath, job :: !FilePath, prompt :: !FilePath}

agentFiles :: FilePath -> AgentFiles
agentFiles directory =
  AgentFiles
    { evidence = directory </> "evidence.json",
      job = directory </> "job.kdl",
      prompt = directory </> "prompt.md"
    }

-- | Launch or reattach, restart-safely.
attemptStep :: LocalCodingAgentConfig -> LocalWorkspace -> CodingAgentAdmission -> IO (AttemptResult Value)
attemptStep config local admission@CodingAgentAdmission {attemptDirectory, root, child} =
  runAttempt attemptDirectory admission.deadline parseEnvelope hooks launch
  where
    AgentFiles {evidence = evidenceFile, job = jobFile, prompt = promptFile} = agentFiles attemptDirectory
    hooks =
      AttemptHooks
        { launched = \LaunchRecord {pid} -> appendEntry local admission "coding-agent.launched" (object ["provider" .= providerText admission.step.provider, "access" .= accessText admission.step.access, "attempt" .= attemptDirectory, "pid" .= pid, "child" .= child]),
          reattached = \LaunchRecord {pid} -> appendEntry local admission "coding-agent.reattached" (object ["attempt" .= attemptDirectory, "pid" .= pid, "child" .= child])
        }
    launch = do
      now <- getCurrentTime
      let minutesLeft = max 1 (ceiling (diffUTCTime admission.deadline now / 60) :: Integer)
      prompt <- composedPrompt admission
      ByteString.writeFile jobFile (Text.Encoding.encodeUtf8 (jobKdl admission.step minutesLeft admission.providerArgs))
      ByteString.writeFile promptFile (Text.Encoding.encodeUtf8 prompt)
      pure
        AttemptCommand
          { program = config.launcher,
            arguments = ["unattended", "agent", "run", "shikigami-step", "--config", Text.pack jobFile, "--prompt-file", Text.pack promptFile, "--run-id", child, "--evidence-file", Text.pack evidenceFile, "--json"],
            workingDirectory = root
          }

-- | A complete Baikai envelope is a JSON object with an @outcome@.
parseEnvelope :: ByteString.ByteString -> Maybe Value
parseEnvelope bytes = case Aeson.decodeStrict bytes of
  Just value@(Object fields) | KeyMap.member "outcome" fields -> Just value
  _ -> Nothing

jobKdl :: CodingAgentStep -> Integer -> [Text] -> Text
jobKdl requested minutes providerArgs =
  Text.unlines
    ( [ "jobs {",
        "  shikigami-step {",
        "    provider " <> quote (providerText requested.provider),
        "    working-dir \".\"",
        "    timeout " <> quote (Text.pack (show minutes) <> "m"),
        "    output \"capture\"",
        "    output-format \"json\"",
        "    output-limit 1048576"
      ]
        <> maybe [] (\m -> ["    model " <> quote (vendorModelIdText m)]) requested.model
        <> maybe [] (\e -> ["    effort " <> quote (effortText e)]) requested.effort
        <> [ "    safety {",
             "      capability " <> quote (accessText requested.access)
           ]
        <> ["      provider-args " <> Text.unwords (quote <$> providerArgs) | not (null providerArgs)]
        <> [ "    }",
             "  }",
             "}"
           ]
    )
  where
    quote value = "\"" <> Text.replace "\"" "\\\"" value <> "\""

-- | The declaration's prompt, a fixed preamble about the worktree, each
-- attached skill inlined, and the trigger payload quoted as evidence.
composedPrompt :: CodingAgentAdmission -> IO Text
composedPrompt CodingAgentAdmission {step = requested, root, branch, skills, toolLines} = do
  inlined <- forM skills \(name, copy) -> do
    content <- try (ByteString.readFile (copy </> "SKILL.md"))
    pure case content of
      Right bytes -> "### Skill " <> name <> " (" <> Text.pack copy <> ")\n\n" <> Text.Encoding.decodeUtf8Lenient (ByteString.take 32768 bytes) <> "\n"
      Left (_ :: IOException) -> ""
  pure
    ( codingAgentPromptText requested.prompt
        <> "\n\n---\n\nYou are working in the Git worktree "
        <> Text.pack root
        <> " on branch "
        <> branch
        <> ". Make your changes there. Do not push, do not create or switch branches, and do not commit: Shikigami commits your changes when you finish. End with a short summary of what you changed.\n"
        <> (if null toolLines then "" else "\nThe only shell commands you may run are these declared tools, one plain command per call (no pipes, redirection or variables); anything else is refused and recorded:\n" <> Text.unlines (("- " <>) <$> toolLines))
        <> if null skills then "" else "\nRead these attached skills before you start; they describe how to do this kind of task.\n\n" <> Text.concat inlined
    )

-- | Map the collected envelope or the uncertainty to the step's outcome,
-- committing a completed change on the run branch.
settleStep :: LocalWorkspace -> CodingAgentAdmission -> AttemptResult Value -> IO CodingAgentOutcome
settleStep local admission result = do
  outcome <- case result of
    GaveUp reason -> do
      uncommitted <- statusSummary admission.root
      launch <- readJson (attemptFiles admission.attemptDirectory).launch
      appendEntry local admission "coding-agent.uncertain" (object ["reason" .= reason, "child" .= admission.child, "pid" .= ((\LaunchRecord {pid} -> pid) <$> launch)])
      pure (Uncertain UncertainRun {reason, uncommitted, launcherPid = (\LaunchRecord {pid} -> pid) <$> launch})
    NotLaunched detail -> pure (Failed (Unstartable detail))
    Collected envelope -> do
      evidence <- evidenceSummary admission.attemptDirectory
      settleEnvelope local admission envelope evidence
  importGateDecisions local admission
  appendEntry local admission "coding-agent.settled" (object ["outcome" .= outcomeLabel outcome, "child" .= admission.child, "detail" .= settledDetail outcome])
  pure outcome
  where
    settledDetail = \case
      Completed CompletedRun {exit, result = commit, changes} -> object ["exit" .= exit, "commit" .= commit, "files" .= length changes.files]
      other -> object ["summary" .= Text.take 256 (renderOutcome other)]

-- | Exit 75 is a timeout; Baikai's own refusals are failures; anything else
-- the agent ran to an end is completed, and its change is committed.
settleEnvelope :: LocalWorkspace -> CodingAgentAdmission -> Value -> Maybe EvidenceSummary -> IO CodingAgentOutcome
settleEnvelope local admission envelope evidence = case (exitCode, outcomeText) of
  (Just 75, _) -> do
    uncommitted <- statusSummary admission.root
    pure (TimedOut PartialRun {limit = admission.step.deadlineMinutes, uncommitted, evidence})
  (Just code, Just outcome)
    | outcome /= "ran", code `elem` [64, 69, 77, 78] -> pure (Failed (failure code))
  (Just code, _) -> do
    committed <- commitChanges local admission
    changes <- changeSummary admission.root admission.base
    pure (Completed CompletedRun {exit = code, changes, result = committed, finalMessage = finalMessageOf envelope, evidence})
  (Nothing, _) -> pure (Failed (Misconfigured "the Baikai envelope carries no exit code"))
  where
    field name = case envelope of
      Object fields -> KeyMap.lookup (Key.fromText name) fields
      _ -> Nothing
    exitCode = case field "exitCode" of
      Just (Number n) -> toBoundedInteger n
      _ -> Nothing
    outcomeText = case field "outcome" of
      Just (String t) -> Just t
      _ -> Nothing
    message = case field "message" of
      Just (String t) -> Text.take 512 t
      _ -> ""
    failure = \case
      77 -> RefusedByCeiling message
      69 -> Unstartable message
      _ -> Misconfigured message

-- | Commit everything the agent changed, only when something changed.
commitChanges :: LocalWorkspace -> CodingAgentAdmission -> IO ResultCommit
commitChanges local admission = do
  status <- gitIn admission.root ["status", "--porcelain"]
  case status of
    Right porcelain | not (Text.null porcelain) -> do
      _ <- gitIn admission.root ["add", "-A"]
      let message = "shikigami(" <> agentNameText local.agent <> "): coding-agent behavior\n\nShikigami-Run: " <> parentOf admission.child <> "\nShikigami-Agent: " <> agentNameText local.agent
      _ <- gitIn admission.root ["-c", "commit.gpgsign=false", "commit", "--no-verify", "--quiet", "-m", message]
      head' <- gitIn admission.root ["rev-parse", "HEAD"]
      pure (either (const (Unchanged admission.base)) Committed head')
    _ -> do
      head' <- gitIn admission.root ["rev-parse", "HEAD"]
      pure (if either (const True) (== admission.base) head' then Unchanged admission.base else either (const (Unchanged admission.base)) Committed head')
  where
    parentOf = fst . Text.breakOn ":coding-agent:"

changeSummary :: FilePath -> Text -> IO ChangeSummary
changeSummary root base = do
  listed <- gitIn root ["diff", "--name-status", base <> "..HEAD"]
  pure (summaryOf (either (const []) Text.lines listed))

statusSummary :: FilePath -> IO ChangeSummary
statusSummary root = do
  listed <- gitIn root ["status", "--porcelain"]
  pure (summaryOf (either (const []) (fmap porcelainToNameStatus . Text.lines) listed))
  where
    porcelainToNameStatus line =
      let (code, path) = Text.splitAt 3 line
       in Text.strip (Text.replace "?" "A" code) <> "\t" <> path

summaryOf :: [Text] -> ChangeSummary
summaryOf lines' =
  let parsed = mapMaybe parse lines'
   in ChangeSummary {files = take 200 parsed, omitted = fromIntegral (max 0 (length parsed - 200))}
  where
    parse line = case Text.splitOn "\t" line of
      code : rest@(_ : _) -> Just ChangedFile {path = last rest, change = changeOf (Text.take 1 code)}
      _ -> Nothing
    changeOf = \case
      "A" -> Added
      "D" -> Deleted
      "R" -> Renamed
      _ -> Modified

-- | The agent's last message: Claude's JSON @result@, else the captured text.
finalMessageOf :: Value -> Text
finalMessageOf envelope = Text.take 16384 case envelope of
  Object fields -> case KeyMap.lookup "stdout" fields of
    Just (String out) -> case Aeson.decodeStrict (Text.Encoding.encodeUtf8 out) of
      Just (Object vendor) | Just (String result) <- KeyMap.lookup "result" vendor -> result
      -- Claude Code's JSON output is the event list; its last event of type
      -- @result@ carries the final message.
      Just (Array events) | (result : _) <- reverse [r | Object event <- foldr (:) [] events, KeyMap.lookup "type" event == Just (String "result"), Just (String r) <- [KeyMap.lookup "result" event]] -> result
      -- Codex's @--json@ output is one event per line; the final message is
      -- the text of its last completed @agent_message@ item.
      _ | (message : _) <- reverse (mapMaybe codexMessage (Text.lines out)) -> message
      _ -> lastNonEmpty out
    _ -> ""
  _ -> ""
  where
    codexMessage line = case Aeson.decodeStrict (Text.Encoding.encodeUtf8 line) of
      Just (Object event)
        | KeyMap.lookup "type" event == Just (String "item.completed"),
          Just (Object item) <- KeyMap.lookup "item" event,
          KeyMap.lookup "type" item == Just (String "agent_message"),
          Just (String text) <- KeyMap.lookup "text" item ->
            Just text
      _ -> Nothing
    lastNonEmpty out = case reverse (filter (not . Text.null . Text.strip) (Text.lines out)) of
      line : _ -> line
      [] -> ""

evidenceSummary :: FilePath -> IO (Maybe EvidenceSummary)
evidenceSummary directory = do
  let evidenceFile = (agentFiles directory).evidence
  exists <- doesFileExist evidenceFile
  if not exists
    then pure Nothing
    else do
      bytes <- ByteString.readFile evidenceFile
      let text name = case Aeson.decodeStrict bytes of
            Just (Object fields) | Just (String value) <- KeyMap.lookup name fields -> Just value
            _ -> Nothing
      pure
        ( Just
            EvidenceSummary
              { file = evidenceFile,
                digest = versionedDigest "shikigami.coding-agent-evidence/1" (Text.Encoding.decodeUtf8Lenient bytes),
                strength = fromMaybe "unknown" (text "strength"),
                session = text "session_id",
                reportedModel = text "model"
              }
        )

-- | The gate's decisions, one JSON object per line, become @tool.called@
-- entries of the run.
importGateDecisions :: LocalWorkspace -> CodingAgentAdmission -> IO ()
importGateDecisions local admission = do
  let path = admission.attemptDirectory </> "tool-calls.jsonl"
  exists <- doesFileExist path
  if not exists
    then pure ()
    else do
      lines' <- ByteString.split 10 <$> ByteString.readFile path
      forM_ [value | line <- lines', Just value@(Object _) <- [Aeson.decodeStrict line]] \value ->
        appendEntry local admission "tool.called" value

appendEntry :: LocalWorkspace -> CodingAgentAdmission -> Text -> Value -> IO ()
appendEntry local admission kindText payload = do
  at <- getCurrentTime
  case mkRecordKind kindText of
    Right kind
      | Right entry <- mkRecordEntry kind payload ->
          void (local.record.append RecordEvent {at, run = Just (WorkflowId (fst (Text.breakOn ":coding-agent:" admission.child))), principal = declarationCoordinateText local.principal, tier = local.tier, agent = Just local.agent, entry})
    _ -> pure ()

readJson :: (Aeson.FromJSON a) => FilePath -> IO (Maybe a)
readJson path = do
  exists <- doesFileExist path
  if exists then Aeson.decodeStrict <$> ByteString.readFile path else pure Nothing

safeName :: Text -> Text
safeName = Text.map (\c -> if isAlphaNum c || c == '-' then c else '_')
