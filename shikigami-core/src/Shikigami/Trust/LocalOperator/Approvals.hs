-- | The explicit approvals file of the 'LocalOperator' tier
-- (@schema/LocalOperator.dhall@).
--
-- The file is optional: a missing file is an empty set of explicit approvals.
-- Decoded input is plain data; the validated values are sealed and read
-- through 'HasField' views. Validation is IO because it canonicalizes sources,
-- asks @mori path@ for a source that is omitted, and resolves rule programs on
-- @PATH@.
module Shikigami.Trust.LocalOperator.Approvals
  ( -- * Placement
    WorkspacePlacement (..),
    placementText,

    -- * Validated approvals
    LocalApprovals,
    LocalRepository,
    AgentApproval,
    ApprovedRule (..),
    RuleName,
    mkRuleName,
    ruleNameText,
    ProgramPath,
    programPathText,
    LaunchDeadline,
    launchDeadlineSeconds,
    OutputLimit,
    outputLimitBytes,
    Budget (..),
    defaultBudget,
    emptyApprovals,
    workspaceCapabilityIds,

    -- * Loading and selection
    CheckoutResolver (..),
    ApprovalsError (..),
    renderApprovalsError,
    defaultApprovalsPath,
    loadLocalApprovals,
    RepositorySelector (..),
    selectRepository,
    approvalFor,
  )
where

import Control.Exception (SomeException, try)
import Control.Monad (forM, when)
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.List (find, nub)
import Data.Maybe (isNothing)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (FromDhall, auto, inputFile)
import GHC.Generics (Generic)
import GHC.Records (HasField (..))
import Numeric.Natural (Natural)
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Capability.Overlay (CapabilityId, capabilityIdText, mkCapabilityId)
import Shikigami.Repository (RepositoryId, repositoryId, repositoryIdText)
import System.Directory (XdgDirectory (XdgConfig), canonicalizePath, doesDirectoryExist, doesFileExist, findExecutable, getXdgDirectory)
import System.FilePath (isAbsolute, (</>))

-- | Where a run works in an approved repository.
data WorkspacePlacement
  = -- | A run branch in its own worktree (the default).
    SeparateWorktree
  | -- | The checkout itself, on its current branch. For repositories nobody
    -- else is working in.
    InPlace
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromDhall)

placementText :: WorkspacePlacement -> Text
placementText = \case
  SeparateWorktree -> "separate worktree on a run branch"
  InPlace -> "in place on the checkout's current branch"

instance ToJSON WorkspacePlacement where
  toJSON = \case
    SeparateWorktree -> "separate-worktree"
    InPlace -> "in-place"

instance FromJSON WorkspacePlacement where
  parseJSON = Aeson.withText "WorkspacePlacement" \case
    "separate-worktree" -> pure SeparateWorktree
    "in-place" -> pure InPlace
    other -> fail ("unknown placement " <> Text.unpack other)

data RuleInput = RuleInput {name :: !Text, argv :: ![Text], inherit :: ![Text], timeoutSeconds :: !Natural, outputBytes :: !Natural}
  deriving stock (Generic)
  deriving anyclass (FromDhall)

data BudgetInput = BudgetInput {modelAttempts :: !Natural, toolAttempts :: !Natural, tokens :: !Natural, minutes :: !Natural}
  deriving stock (Generic)
  deriving anyclass (FromDhall)

data RepositoryInput = RepositoryInput {identity :: !Text, source :: !(Maybe Text), base :: !Text, placement :: !WorkspacePlacement}
  deriving stock (Generic)
  deriving anyclass (FromDhall)

data AgentApprovalInput = AgentApprovalInput
  {agent :: !Text, repository :: !Text, capabilities :: ![Text], rules :: ![RuleInput], budget :: !(Maybe BudgetInput)}
  deriving stock (Generic)
  deriving anyclass (FromDhall)

data LocalApprovalsInput = LocalApprovalsInput {repositories :: ![RepositoryInput], agents :: ![AgentApprovalInput]}
  deriving stock (Generic)
  deriving anyclass (FromDhall)

-- | The resource budget of a grant. A grant that states none uses
-- 'defaultBudget'.
data Budget = Budget {modelAttempts :: !Natural, toolAttempts :: !Natural, tokens :: !Natural, minutes :: !Natural}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | 30 model attempts, 120 tool attempts, 3,000,000 tokens, 60 minutes.
defaultBudget :: Budget
defaultBudget = Budget {modelAttempts = 30, toolAttempts = 120, tokens = 3000000, minutes = 60}

newtype RuleName = RuleName Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

-- | @[a-z][a-z0-9-]{0,63}@.
mkRuleName :: Text -> Either Text RuleName
mkRuleName value = case Text.uncons value of
  Just (first', rest)
    | first' >= 'a' && first' <= 'z',
      Text.length value <= 64,
      Text.all (\c -> (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') rest ->
        Right (RuleName value)
  _ -> Left ("rule name must match [a-z][a-z0-9-]{0,63}: " <> value)

ruleNameText :: RuleName -> Text
ruleNameText (RuleName value) = value

newtype ProgramPath = ProgramPath FilePath
  deriving stock (Eq, Show)

programPathText :: ProgramPath -> Text
programPathText (ProgramPath path) = Text.pack path

newtype LaunchDeadline = LaunchDeadline Natural
  deriving stock (Eq, Show)

launchDeadlineSeconds :: LaunchDeadline -> Natural
launchDeadlineSeconds (LaunchDeadline seconds) = seconds

newtype OutputLimit = OutputLimit Natural
  deriving stock (Eq, Show)

outputLimitBytes :: OutputLimit -> Natural
outputLimitBytes (OutputLimit bytes) = bytes

-- | One approved command line.
data ApprovedRule = ApprovedRule
  { name :: !RuleName,
    program :: !ProgramPath,
    arguments :: ![Text],
    inherit :: ![Text],
    deadline :: !LaunchDeadline,
    outputLimit :: !OutputLimit
  }
  deriving stock (Eq, Show)

-- | An approved repository with its resolved checkout.
data LocalRepository = LocalRepository !RepositoryId !FilePath !Text !WorkspacePlacement
  deriving stock (Eq, Show)

instance HasField "identity" LocalRepository RepositoryId where getField (LocalRepository identity _ _ _) = identity

instance HasField "source" LocalRepository FilePath where getField (LocalRepository _ source _ _) = source

instance HasField "base" LocalRepository Text where getField (LocalRepository _ _ base _) = base

instance HasField "placement" LocalRepository WorkspacePlacement where getField (LocalRepository _ _ _ placement) = placement

-- | One explicit approval of an agent on a repository.
data AgentApproval = AgentApproval !AgentName !RepositoryId !(Set CapabilityId) ![ApprovedRule] !(Maybe Budget)
  deriving stock (Eq, Show)

instance HasField "agent" AgentApproval AgentName where getField (AgentApproval agent _ _ _ _) = agent

instance HasField "repository" AgentApproval RepositoryId where getField (AgentApproval _ repository _ _ _) = repository

instance HasField "capabilities" AgentApproval (Set CapabilityId) where getField (AgentApproval _ _ capabilities _ _) = capabilities

instance HasField "rules" AgentApproval [ApprovedRule] where getField (AgentApproval _ _ _ rules _) = rules

instance HasField "budget" AgentApproval (Maybe Budget) where getField (AgentApproval _ _ _ _ budget) = budget

data LocalApprovals = LocalApprovals ![LocalRepository] ![AgentApproval]
  deriving stock (Eq, Show)

instance HasField "repositories" LocalApprovals [LocalRepository] where getField (LocalApprovals repositories _) = repositories

instance HasField "approvals" LocalApprovals [AgentApproval] where getField (LocalApprovals _ approvals) = approvals

emptyApprovals :: LocalApprovals
emptyApprovals = LocalApprovals [] []

-- | The capability ids an approval may name until EP-3 adds declared tools.
workspaceCapabilityIds :: Set CapabilityId
workspaceCapabilityIds =
  Set.fromList [either (error . show) id (mkCapabilityId c) | c <- ["workspace.read", "workspace.edit", "workspace.exec", "workspace.git"]]

data ApprovalsError
  = ApprovalsDhallInvalid !Text
  | RepositoryIdentityInvalid !Text
  | DuplicateRepository !Text
  | RepositorySourceUnresolvable !Text !Text
  | RepositoryNotGitToplevel !FilePath
  | UnknownRepository !Text
  | UnknownCapability !Text !Text
  | DuplicateApproval !Text !Text
  | InvalidAgentName !Text
  | InvalidRule !Text !Text
  | MissingProgram !Text !Text
  deriving stock (Eq, Show)

renderApprovalsError :: ApprovalsError -> Text
renderApprovalsError = \case
  ApprovalsDhallInvalid detail -> "the approvals file is not valid: " <> detail
  RepositoryIdentityInvalid identity -> "repository identity must be non-empty and have no whitespace: " <> identity
  DuplicateRepository identity -> "repository " <> identity <> " is listed twice"
  RepositorySourceUnresolvable identity detail -> "cannot resolve a checkout for " <> identity <> ": " <> detail
  RepositoryNotGitToplevel path -> Text.pack path <> " is not the top level of a Git checkout"
  UnknownRepository identity -> "repository " <> identity <> " is not listed in repositories"
  UnknownCapability agent capability -> "agent " <> agent <> " names unknown capability " <> capability
  DuplicateApproval agent identity -> "agent " <> agent <> " is approved twice for " <> identity
  InvalidAgentName detail -> "invalid agent name: " <> detail
  InvalidRule rule detail -> "rule " <> rule <> " is invalid: " <> detail
  MissingProgram rule program -> "rule " <> rule <> " names " <> program <> ", which is not an executable on PATH"

-- | How a composition finds checkouts. The kernel spawns no process, so the
-- host adapter that runs @git@ and @mori@ is supplied by the composition
-- (@Shikigami.Agent.Checkout@ for the light commands).
data CheckoutResolver = CheckoutResolver
  { -- | The canonical top level of the Git checkout containing a directory.
    toplevelOf :: !(FilePath -> IO (Either Text FilePath)),
    -- | @mori path <identity>@.
    moriPath :: !(Text -> IO (Either Text FilePath)),
    -- | The @mori://namespace/name@ identity of a checkout, when Mori knows it.
    moriIdentity :: !(FilePath -> IO (Maybe Text))
  }

-- | @$XDG_CONFIG_HOME/shikigami/local-operator.dhall@.
defaultApprovalsPath :: IO FilePath
defaultApprovalsPath = (</> "local-operator.dhall") <$> getXdgDirectory XdgConfig "shikigami"

-- | Load and validate the approvals file. A missing file is empty.
loadLocalApprovals :: CheckoutResolver -> FilePath -> IO (Either ApprovalsError LocalApprovals)
loadLocalApprovals resolver path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right emptyApprovals)
    else do
      decoded <- try (inputFile auto path)
      case decoded of
        Left (problem :: SomeException) -> pure (Left (ApprovalsDhallInvalid (Text.pack (show problem))))
        Right input -> validate input
  where
    validate LocalApprovalsInput {repositories, agents} = do
      let identities = (\RepositoryInput {identity} -> identity) <$> repositories
      case find (\i -> length (filter (== i) identities) > 1) identities of
        Just duplicate -> pure (Left (DuplicateRepository duplicate))
        Nothing -> do
          resolved <- sequence <$> mapM (validateRepository resolver) repositories
          case resolved of
            Left problem -> pure (Left problem)
            Right repos -> do
              approvals <- sequence <$> mapM (validateApproval repos) agents
              pure case approvals of
                Left problem -> Left problem
                Right valid
                  | Just (AgentApproval agent repository _ _ _) <- duplicateApproval valid ->
                      Left (DuplicateApproval (agentNameText agent) (repositoryIdText repository))
                  | otherwise -> Right (LocalApprovals repos valid)
    duplicateApproval valid =
      find (\a -> length (filter (sameKey a) valid) > 1) valid
    sameKey (AgentApproval a r _ _ _) (AgentApproval b s _ _ _) = a == b && r == s

validateRepository :: CheckoutResolver -> RepositoryInput -> IO (Either ApprovalsError LocalRepository)
validateRepository resolver RepositoryInput {identity, source, base, placement}
  | Text.null identity || Text.any (== ' ') identity = pure (Left (RepositoryIdentityInvalid identity))
  | otherwise = do
      path <- case source of
        Just given -> pure (Right (Text.unpack given))
        Nothing -> resolver.moriPath identity
      case path of
        Left detail -> pure (Left (RepositorySourceUnresolvable identity detail))
        Right raw -> fmap (\top -> LocalRepository (repositoryId identity) top base placement) <$> gitToplevel resolver raw

validateApproval :: [LocalRepository] -> AgentApprovalInput -> IO (Either ApprovalsError AgentApproval)
validateApproval repos AgentApprovalInput {agent, repository, capabilities, rules, budget} =
  case mkAgentName agent of
    Left detail -> pure (Left (InvalidAgentName detail))
    Right agentName
      | isNothing (find (\r -> repositoryIdText r.identity == repository) repos) -> pure (Left (UnknownRepository repository))
      | otherwise -> do
          let parsed = forM capabilities \c -> case mkCapabilityId c of
                Right capability | capability `Set.member` workspaceCapabilityIds -> Right capability
                _ -> Left (UnknownCapability agent c)
          case parsed of
            Left problem -> pure (Left problem)
            Right ids -> do
              checkedRules <- sequence <$> mapM validateRule rules
              pure do
                valid <- checkedRules
                when (length (nub (fmap (\r -> r.name) valid)) /= length valid) (Left (InvalidRule agent "rule names must be unique"))
                pure (AgentApproval agentName (repositoryId repository) (Set.fromList ids) valid (fmap toBudget budget))
  where
    toBudget BudgetInput {modelAttempts, toolAttempts, tokens, minutes} = Budget {modelAttempts, toolAttempts, tokens, minutes}

validateRule :: RuleInput -> IO (Either ApprovalsError ApprovedRule)
validateRule RuleInput {name, argv, inherit, timeoutSeconds, outputBytes} =
  case (mkRuleName name, argv) of
    (Left detail, _) -> pure (Left (InvalidRule name detail))
    (_, []) -> pure (Left (InvalidRule name "argv must name a program"))
    (Right ruleName, program : arguments)
      | timeoutSeconds < 1 || timeoutSeconds > 86400 -> pure (Left (InvalidRule name "timeoutSeconds must be 1 to 86400"))
      | outputBytes < 1024 || outputBytes > 1048576 -> pure (Left (InvalidRule name "outputBytes must be 1024 to 1048576"))
      | otherwise -> do
          resolved <-
            if isAbsolute (Text.unpack program)
              then (\exists -> if exists then Just (Text.unpack program) else Nothing) <$> doesFileExist (Text.unpack program)
              else findExecutable (Text.unpack program)
          pure case resolved of
            Nothing -> Left (MissingProgram name program)
            Just path ->
              Right ApprovedRule {name = ruleName, program = ProgramPath path, arguments, inherit, deadline = LaunchDeadline timeoutSeconds, outputLimit = OutputLimit outputBytes}

-- | How the caller names the repository of a run.
data RepositorySelector
  = SelectByIdentity !RepositoryId
  | SelectByPath !FilePath
  deriving stock (Eq, Show)

-- | The approved repository the selector names, or an unlisted checkout with
-- the default placement and base @HEAD@. An unlisted path takes its Mori
-- identity when @mori status@ reports one, and @file://<toplevel>@ otherwise.
selectRepository :: CheckoutResolver -> LocalApprovals -> RepositorySelector -> IO (Either ApprovalsError LocalRepository)
selectRepository resolver (LocalApprovals repos _) = \case
  SelectByIdentity identity -> case find (\r -> r.identity == identity) repos of
    Just listed -> pure (Right listed)
    Nothing ->
      resolver.moriPath (repositoryIdText identity) >>= \case
        Left detail -> pure (Left (RepositorySourceUnresolvable (repositoryIdText identity) detail))
        Right path -> fmap (\top -> LocalRepository identity top "HEAD" SeparateWorktree) <$> gitToplevel resolver path
  SelectByPath path ->
    gitToplevelOf resolver path >>= \case
      Left problem -> pure (Left problem)
      Right top -> case find (\r -> r.source == top) repos of
        Just listed -> pure (Right listed)
        Nothing -> do
          identity <- resolver.moriIdentity top
          pure (Right (LocalRepository (repositoryId (maybe ("file://" <> Text.pack top) id identity)) top "HEAD" SeparateWorktree))

approvalFor :: LocalApprovals -> AgentName -> LocalRepository -> Maybe AgentApproval
approvalFor (LocalApprovals _ approvals) agent repository =
  find (\(AgentApproval a r _ _ _) -> a == agent && r == repository.identity) approvals

-- | The canonical top level of the Git checkout that contains a directory.
gitToplevelOf :: CheckoutResolver -> FilePath -> IO (Either ApprovalsError FilePath)
gitToplevelOf resolver raw = do
  isDirectory <- doesDirectoryExist raw
  if not isDirectory
    then pure (Left (RepositoryNotGitToplevel raw))
    else do
      canonical <- canonicalizePath raw
      resolver.toplevelOf canonical >>= \case
        Right top -> Right <$> canonicalizePath top
        Left _ -> pure (Left (RepositoryNotGitToplevel canonical))

-- | An approved source must be the top level of its checkout, not a
-- directory inside one.
gitToplevel :: CheckoutResolver -> FilePath -> IO (Either ApprovalsError FilePath)
gitToplevel resolver raw =
  gitToplevelOf resolver raw >>= \case
    Right top -> do
      canonical <- canonicalizePath raw
      pure (if top == canonical then Right top else Left (RepositoryNotGitToplevel canonical))
    Left problem -> pure (Left problem)
