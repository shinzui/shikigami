{-# LANGUAGE DataKinds #-}

-- | The mutating workspace tools of the local-operator tier.
--
-- @workspace.edit@, @workspace.exec@ and @workspace.git@ at revision
-- @local-1@ act in the run's worktree on the operator's machine. Each tool
-- refuses a snapshot that was not admitted by 'localWorkspaceHost' (provider
-- @shikigami.workspace.local/1@, file policy 'LocalHostFilesV1'), asks the
-- run's authority before any IO, and appends its effect to the action record
-- (ADR-124). Paths and rule names come from the model; worktree roots and
-- programs never do.
module Shikigami.Workspace.Local.Adapters
  ( LocalWorkspace (..),
    localProvider,
    localWorkspaceDescriptors,
    localWorkspaceAdapters,
    localWorkspaceHost,

    -- * Tool bodies, for tests
    ToolBody,
    editTool,
    execTool,
    gitTool,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (forM)
import Data.Aeson (Value, object, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.List (isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Time (getCurrentTime)
import Effectful.Dispatch.Static (unsafeEff_)
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinateText)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Authority (Authority, Principal, invokeToolAction)
import Shikigami.Capability.Overlay
import Shikigami.Capability.Provider (CapabilityRuntime, DurableAdapter (..), DurableToolContract (..))
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Execution.Coordinate (ExecutionCoordinate, executionCoordinate, executionCoordinateText)
import Shikigami.Execution.Policy.Types (RecoveryClass (..), ToolInvoiceCost (..))
import Shikigami.Execution.Selection (ExecutionSelection (..))
import Shikigami.Execution.Start (SkillAssignment (..))
import Shikigami.Execution.Transcript (ExecutionError (..), ExecutionSnapshot (..))
import Shikigami.Record (ActionRecord (..), RecordEvent (..), TierLabel, mkRecordEntry, mkRecordKind)
import Shikigami.Repository (repositoryIdText)
import Shikigami.StateRevision (initialRevision)
import Shikigami.Trust.LocalOperator.Approvals
import Shikigami.Trust.LocalOperator.Grant (LocalGrant)
import Shikigami.Workspace.Admission (WorkspaceHost (..))
import Shikigami.Workspace.Instructions (WorkspaceAdmission (..), mkInstructionBundle, validWorkspacePath)
import Shikigami.Workspace.Launch
import Shikigami.Workspace.Local.Worktree
import Shikigami.Workspace.Reference (WorkspaceRef (..))
import Shikigami.Workspace.Value (FilePolicy (LocalHostFilesV1), workspaceCoordinate, workspaceCoordinateText)
import Shikumi.Tool (SomeTool, ToolError (..), mkDynTool)
import Shikumi.Tool.Output (textToolOutput)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath (splitDirectories, takeDirectory, (</>))
import System.Posix.Files (getSymbolicLinkStatus, isSymbolicLink)

-- | What the local tools act on for one run: the grant and repository it was
-- resolved with, the run's (recorded, run-scoped) authority and record, and
-- the host launcher.
data LocalWorkspace = LocalWorkspace
  { stateDirectory :: !FilePath,
    agent :: !AgentName,
    principal :: !Principal,
    repository :: !LocalRepository,
    grant :: !LocalGrant,
    authority :: !Authority,
    record :: !ActionRecord,
    tier :: !TierLabel,
    launcher :: !ProcessLauncher,
    git :: !ProgramPath
  }

localProvider :: Text
localProvider = "shikigami.workspace.local/1"

localRevision :: CapabilityRevision
localRevision = must (mkCapabilityRevision "local-1")

descriptor :: Text -> [(Text, CapabilityOperationClass)] -> CapabilityDescriptor
descriptor capability tools =
  CapabilityDescriptor (must (mkCapabilityId capability)) localRevision [CapabilityToolDescriptor (executionCoordinate name) operation | (name, operation) <- tools]

editDescriptor, execDescriptor, gitDescriptor :: CapabilityDescriptor
editDescriptor = descriptor "workspace.edit" [("read", Observation), ("replace", IdempotentMutation)]
execDescriptor = descriptor "workspace.exec" [("run", IdempotentMutation)]
gitDescriptor = descriptor "workspace.git" [("status", Observation), ("diff", Observation), ("commit", IdempotentMutation)]

localWorkspaceDescriptors :: [CapabilityDescriptor]
localWorkspaceDescriptors = [editDescriptor, execDescriptor, gitDescriptor]

localWorkspaceAdapters :: LocalWorkspace -> [DurableAdapter]
localWorkspaceAdapters local =
  [ adapter editDescriptor editContracts editTool,
    adapter execDescriptor execContracts execTool,
    adapter gitDescriptor gitContracts gitTool
  ]
  where
    adapter descriptor' contracts body = DurableAdapter descriptor' contracts (prepareWith local contracts body)
    editContracts =
      [ contract "read" "Read a UTF-8 file of the run's worktree (at most 256 KiB). Returns its content and contentDigest." (schema ["path"]) RepeatableObservation,
        contract "replace" "Write a file of the run's worktree. Give the contentDigest read before (empty for a new file); replaying the same content succeeds." (schema ["path", "expected", "content"]) IdempotentEffect
      ]
    execContracts =
      [ contract "run" ("Run one operator-approved command rule in the run's worktree under its deadline. Approved rules: " <> approvedRules <> ".") (schema ["rule"]) UncertainEffect
      ]
    gitContracts =
      [ contract "status" "Show git status --porcelain of the run's worktree and its HEAD." (schema []) RepeatableObservation,
        contract "diff" "Show git diff of the run's worktree (at most 32 KiB)." (schema []) RepeatableObservation,
        contract "commit" "Commit every change in the run's worktree with a message. expectedParent must be the HEAD that status reported." (schema ["message", "expectedParent"]) UncertainEffect
      ]
    approvedRules = case ruleNameText . (.name) <$> local.grant.rules of
      [] -> "none"
      names -> Text.intercalate ", " names
    contract name description' schema' recovery = DurableToolContract (executionCoordinate name) description' schema' recovery NoInvoiceCost
    schema fields =
      object
        [ "type" .= ("object" :: Text),
          "properties" .= object [Key.fromText field .= object ["type" .= ("string" :: Text)] | field <- fields],
          "required" .= fields,
          "additionalProperties" .= False
        ]

-- | One tool's effect for a run: its worktree, the tool name and the model's
-- input.
type ToolBody = LocalWorkspace -> WorkflowId -> RunWorktree -> Text -> Value -> IO (Either Text Value)

-- | Refuse a snapshot this host did not admit, reopen the run's worktree,
-- and build the named tool over it.
prepareWith :: LocalWorkspace -> [DurableToolContract] -> ToolBody -> ExecutionSnapshot -> a -> ExecutionCoordinate "tool-name" -> IO (Either ExecutionError SomeTool)
prepareWith local contracts body snapshot _dispatch requested = case snapshot.workspace of
  Just admission
    | workspaceCoordinateText admission.workspace.provider == localProvider,
      admission.filePolicy == Just LocalHostFilesV1 ->
        openRunWorktree local.stateDirectory local.agent snapshot.runId local.repository >>= \case
          Left problem -> pure (Left (ExecutionPolicyRefused (renderWorktreeError problem)))
          Right worktree
            | workspaceCoordinateText admission.workspace.resource /= worktree.suffix -> pure (Left (ExecutionPolicyRefused "the admitted worktree is not this run's"))
            | otherwise -> case [c | c <- contracts, c.name == requested] of
                [] -> pure (Left (ExecutionPolicyRefused "unknown local workspace tool"))
                DurableToolContract {description, schema} : _ -> do
                  let name = executionCoordinateText requested
                  pure
                    ( Right
                        ( mkDynTool name description schema \input -> unsafeEff_ do
                            result <- body local snapshot.runId worktree name input
                            pure (either (Left . ToolRunFailed name) (Right . textToolOutput . Text.Encoding.decodeUtf8 . ByteString.toStrict . Aeson.encode) result)
                        )
                    )
  _ -> pure (Left (ExecutionPolicyRefused "the snapshot was not admitted by the local workspace host"))

-- | Ask the run's authority for one tool call before any IO.
authorize :: LocalWorkspace -> Text -> Text -> IO (Either Text ())
authorize local capability tool = case invokeToolAction capability "local-1" tool of
  Left problem -> pure (Left problem)
  Right action -> first (const ("the operator did not grant " <> capability <> " " <> tool)) . fmap (const ()) <$> local.authority.decide local.principal action

editTool :: ToolBody
editTool local _runId worktree name input = case name of
  "read" -> withPath root input \path -> do
    allowed <- authorize local "workspace.edit" "read"
    case allowed of
      Left problem -> pure (Left problem)
      Right () -> do
        bytes <- try (ByteString.readFile (root </> path))
        pure case bytes of
          Left (_ :: IOException) -> Left "the file does not exist or cannot be read"
          Right content
            | ByteString.length content > 262144 -> Left "the file is larger than 256 KiB"
            | otherwise -> case Text.Encoding.decodeUtf8' content of
                Left _ -> Left "the file is not UTF-8 text"
                Right text -> Right (object ["path" .= path, "content" .= text, "contentDigest" .= digestOf content])
  "replace" -> withPath root input \path -> case parseEither (Aeson.withObject "replace" \o -> (,) <$> o .: "expected" <*> o .: "content") input of
    Left problem -> pure (Left (Text.pack problem))
    Right (expected :: Text, content :: Text)
      | ByteString.length (Text.Encoding.encodeUtf8 content) > 262144 -> pure (Left "the content is larger than 256 KiB")
      | otherwise ->
          authorize local "workspace.edit" "replace" >>= \case
            Left problem -> pure (Left problem)
            Right () -> do
              let target = root </> path
                  wanted = Text.Encoding.encodeUtf8 content
              exists <- doesFileExist target
              current <- if exists then Just <$> ByteString.readFile target else pure Nothing
              case current of
                Just bytes | bytes == wanted -> pure (Right (object ["path" .= path, "contentDigest" .= digestOf wanted, "changed" .= False]))
                _
                  | maybe "" digestOf current /= expected -> pure (Left "the file changed since it was read; read it again")
                  | otherwise -> do
                      createDirectoryIfMissing True (takeDirectory target)
                      ByteString.writeFile (target <> ".shikigami-tmp") wanted
                      renameFile (target <> ".shikigami-tmp") target
                      pure (Right (object ["path" .= path, "contentDigest" .= digestOf wanted, "changed" .= True]))
  _ -> pure (Left "unknown tool")
  where
    root = worktreeRootPath worktree.root

execTool :: ToolBody
execTool local runId worktree _name input = case parseEither (Aeson.withObject "run" (.: "rule")) input of
  Left problem -> pure (Left (Text.pack problem))
  Right (rule :: Text) ->
    authorize local "workspace.exec" ("run-" <> rule) >>= \case
      Left _ -> pure (Left ("rule " <> rule <> " is not approved; approved rules: " <> Text.intercalate ", " (ruleNameText . (.name) <$> local.grant.rules)))
      Right () -> case [approved | approved <- local.grant.rules, ruleNameText approved.name == rule] of
        [] -> pure (Left ("rule " <> rule <> " is not approved"))
        approved : _ -> do
          launched <- local.launcher.launch LaunchRequest {program = approved.program, arguments = approved.arguments, directory = worktree.root, inherit = approved.inherit, deadline = approved.deadline, outputLimit = approved.outputLimit}
          case launched of
            Left refusal -> pure (Left (renderLaunchRefusal refusal))
            Right LaunchResult {outcome, stdout, stderr, elapsedMs} -> do
              let exitText = case outcome of
                    Exited code -> Text.pack (show code)
                    DeadlineExpired -> "deadline expired"
              appendEntry local runId "process.finished" (object ["rule" .= rule, "outcome" .= exitText, "elapsedMs" .= elapsedMs, "stdoutDropped" .= stdout.dropped, "stderrDropped" .= stderr.dropped])
              pure (Right (object ["rule" .= rule, "outcome" .= exitText, "stdout" .= stdout.text, "stderr" .= stderr.text, "stdoutDropped" .= stdout.dropped, "stderrDropped" .= stderr.dropped]))

gitTool :: ToolBody
gitTool local runId worktree name input = case name of
  "status" -> observe "status" do
    status <- gitIn root ["status", "--porcelain"]
    headCommit <- gitIn root ["rev-parse", "HEAD"]
    pure (object <$> sequence [("status" .=) <$> status, ("head" .=) <$> headCommit, Right ("branch" .= worktree.branch)])
  "diff" -> observe "diff" do
    diff <- gitIn root ["diff", "HEAD"]
    pure ((\d -> object ["diff" .= Text.take 32768 d, "truncated" .= (Text.length d > 32768)]) <$> diff)
  "commit" -> case parseEither (Aeson.withObject "commit" \o -> (,) <$> o .: "message" <*> o .: "expectedParent") input of
    Left problem -> pure (Left (Text.pack problem))
    Right (message :: Text, expectedParent :: Text) ->
      authorize local "workspace.git" "commit" >>= \case
        Left problem -> pure (Left problem)
        Right () -> do
          headCommit <- gitIn root ["rev-parse", "HEAD"]
          status <- gitIn root ["status", "--porcelain"]
          case (headCommit, status) of
            (Right parent, Right porcelain)
              | parent /= expectedParent -> pure (Left ("HEAD is " <> parent <> ", not the expected parent; call status again"))
              | Text.null porcelain -> pure (Left "nothing changed; there is nothing to commit")
              | otherwise -> do
                  let trailers = "\n\nShikigami-Run: " <> runId.unWorkflowId <> "\nShikigami-Agent: " <> agentNameText local.agent
                  added <- gitIn root ["add", "-A"]
                  committed <- gitIn root ["-c", "commit.gpgsign=false", "commit", "--no-verify", "--quiet", "-m", Text.strip message <> trailers]
                  newHead <- gitIn root ["rev-parse", "HEAD"]
                  case (added, committed, newHead) of
                    (Right _, Right _, Right commit) -> do
                      appendEntry local runId "commit.created" (object ["branch" .= worktree.branch, "parent" .= parent, "commit" .= commit, "repository" .= repositoryIdText worktree.repository])
                      pure (Right (object ["commit" .= commit, "branch" .= worktree.branch, "parent" .= parent]))
                    _ -> pure (Left "git commit failed")
            _ -> pure (Left "git status is unavailable")
  _ -> pure (Left "unknown tool")
  where
    root = worktreeRootPath worktree.root
    observe tool action = authorize local "workspace.git" tool >>= either (pure . Left) (const (first (Text.take 256) <$> action))

-- | A model-supplied relative path, checked before it touches the disk: a
-- workspace path with no @..@, no @.git@ component and no symbolic link.
withPath :: FilePath -> Value -> (FilePath -> IO (Either Text Value)) -> IO (Either Text Value)
withPath root input use = case parseEither (Aeson.withObject "path" (.: "path")) input of
  Left problem -> pure (Left (Text.pack problem))
  Right (raw :: Text)
    | not (validWorkspacePath raw) -> pure (Left "the path must be a relative workspace path")
    | ".git" `elem` Text.splitOn "/" raw -> pure (Left "the path may not name .git")
    | otherwise -> do
        let path = Text.unpack raw
        linked <- anySymlink path
        if linked then pure (Left "the path may not pass through a symbolic link") else use path
  where
    anySymlink path =
      or <$> forM (prefixes (splitDirectories path)) \prefix -> do
        status <- try (getSymbolicLinkStatus (root </> prefix))
        pure (either (\(_ :: IOException) -> False) isSymbolicLink status)
    prefixes parts = [foldr1 (</>) (take n parts) | n <- [1 .. length parts]]

digestOf :: ByteString.ByteString -> Text
digestOf bytes = versionedDigest "shikigami.local-content/1" (Text.Encoding.decodeUtf8Lenient bytes)

-- | Append an effect this host performed (@process.finished@,
-- @commit.created@). The authority already recorded the decision; an
-- effect entry that cannot be appended is reported in the operator log by
-- the observed record, not retried.
appendEntry :: LocalWorkspace -> WorkflowId -> Text -> Value -> IO ()
appendEntry local runId kindText payload = do
  at <- getCurrentTime
  case mkRecordKind kindText >>= first (const "entry too large") . mkRecordEntry' payload of
    Right entry -> () <$ local.record.append RecordEvent {at, run = Just runId, principal = declarationCoordinateText local.principal, tier = local.tier, agent = Just local.agent, entry}
    Left _ -> pure ()
  where
    mkRecordEntry' value kind = mkRecordEntry kind value

-- | The workspace host: open the run's worktree, freeze the instruction
-- files at the base, and admit the snapshot under 'LocalHostFilesV1'.
localWorkspaceHost :: LocalWorkspace -> CapabilityRuntime -> WorkspaceHost
localWorkspaceHost local runtime = WorkspaceHost {capabilities = runtime, load}
  where
    load assignment = case assignment.selection.rootId of
      Nothing -> pure (Left (ExecutionPolicyRefused "a local workspace run needs a resource root"))
      Just root ->
        openRunWorktree local.stateDirectory local.agent assignment.runId local.repository >>= \case
          Left problem -> pure (Left (ExecutionPolicyRefused (renderWorktreeError problem)))
          Right worktree -> do
            either (const (pure ())) (\entry -> appendOpened assignment entry) (worktreeOpenedEntry worktree)
            files <- instructionFiles worktree
            pure case mkInstructionBundle 65536 worktree.repository (workspaceCoordinate worktree.base) files of
              Left _ -> Left (ExecutionPolicyRefused "the repository's instruction files exceed their bound")
              Right instructions ->
                Right
                  WorkspaceAdmission
                    { workspace = WorkspaceRef (workspaceCoordinate localProvider) (workspaceCoordinate worktree.suffix),
                      bindingDigest = workspaceCoordinate (versionedDigest "shikigami.local-binding/1" (repositoryIdText worktree.repository, worktree.base, worktree.branch, worktree.suffix)),
                      runId = assignment.runId,
                      assignmentId = assignment.selection.assignmentId,
                      rootId = root,
                      owner = assignment.identity,
                      epoch = initialRevision,
                      instructions,
                      filePolicy = Just LocalHostFilesV1
                    }
    appendOpened assignment entry = do
      at <- getCurrentTime
      () <$ local.record.append RecordEvent {at, run = Just assignment.runId, principal = declarationCoordinateText local.principal, tier = local.tier, agent = Just local.agent, entry}
    instructionFiles worktree = do
      listed <- gitIn (worktreeRootPath worktree.root) ["ls-tree", "-r", "--name-only", worktree.base]
      let names = either (const []) (filter (\n -> n == "AGENTS.md" || "/AGENTS.md" `isSuffixOf` Text.unpack n) . Text.lines) listed
      fmap concat . forM names $ \n -> do
        shown <- gitIn (worktreeRootPath worktree.root) ["show", worktree.base <> ":" <> n]
        pure (either (const []) (\content -> [(workspaceCoordinate n, content)]) shown)

must :: (Show e) => Either e a -> a
must = either (error . show) id
