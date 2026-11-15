-- | The host composition of the local-operator tier that both the light
-- commands and @shikigami-worker@ use (ADR 0124, ADR 0125).
--
-- A light command resolves one run's ports before it starts. A worker serves
-- many runs, so it resolves a coding-agent step's ports from the step's own
-- input ('queuedCodingAgents'): the declaration by name, the repository the
-- run names, the grant (stored or from the approvals file; a worker never
-- asks), and the run's worktree. Both share 'openLocalRun'.
module Shikigami.Trust.LocalOperator.Host
  ( LocalOperatorPaths (..),
    localRunAuthority,
    recordGrantIn,
    openLocalRun,
    queuedCodingAgents,
    repositorySelectorText,
    codingAgentLauncher,
    gateExecutable,
    nothingGranted,
    compatibilityPrincipal,
  )
where

import Data.Bifunctor (first)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Keiro.Workflow (WorkflowId (..))
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..), codingAgentAccessOf)
import Shikigami.Agent.DeclarationValue (declarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (compatibilityIdentity, identityText)
import Shikigami.Authority
import Shikigami.CodingAgent.Local (LocalCodingAgentConfig (..), localCodingAgentRunner)
import Shikigami.CodingAgent.Types (FailureReason (..))
import Shikigami.CodingAgent.Workflow (CodingAgentRunners, CodingAgentStepInput (..))
import Shikigami.Record (ActionRecord (..), RecordEvent (..), TierLabel, recordErrorText)
import Shikigami.Repository (repositoryId)
import Shikigami.Trust.LocalOperator.Approvals
import Shikigami.Trust.LocalOperator.Authority (LocalSelection (..), isLocalOutput, localOperatorAuthority)
import Shikigami.Trust.LocalOperator.Grant
import Shikigami.Trust.Tier (TrustTier (LocalOperator), trustTierLabel)
import Shikigami.Workspace.Local.Adapters (LocalWorkspace (..))
import Shikigami.Workspace.Local.Checkout (processCheckoutResolver)
import Shikigami.Workspace.Local.Launcher (hostProcessLauncher)
import Shikigami.Workspace.Local.Worktree (RunWorktree (..), openRunWorktree, renderWorktreeError)
import System.Directory (doesFileExist, findExecutable)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath (takeDirectory, (</>))

-- | Where the operator's approvals and the tier's state live.
data LocalOperatorPaths = LocalOperatorPaths
  { approvalsFile :: !FilePath,
    stateDirectory :: !FilePath
  }

-- | The run's authority under a grant, installed over the record and scoped
-- to the run.
localRunAuthority :: ActionRecord -> AgentDecl -> Maybe WorkflowId -> LocalGrant -> Authority
localRunAuthority record decl run grant =
  scopeToRun run decl.name (recorded record tierLabel (localOperatorAuthority LocalSelection {agent = decl.name, principals = actingPrincipals decl, grant}))

-- | Record a grant the operator just gave (or the approvals file supplied).
recordGrantIn :: ActionRecord -> Principal -> Maybe WorkflowId -> AgentName -> LocalGrant -> IO (Either Text ())
recordGrantIn record principal run agentName grant = do
  at <- getCurrentTime
  case grantEntry grant of
    Left problem -> pure (Left problem)
    Right entry ->
      first recordErrorText
        <$> record.append RecordEvent {at, run, principal = declarationCoordinateText principal, tier = tierLabel, agent = Just agentName, entry}

-- | Open the run's worktree and the workspace its local tools and coding
-- agents act in.
openLocalRun :: FilePath -> ActionRecord -> AgentDecl -> Authority -> LocalGrant -> LocalRepository -> WorkflowId -> IO (Either Text (LocalWorkspace, RunWorktree))
openLocalRun stateDirectory record decl runAuthority grant repo runId =
  openRunWorktree stateDirectory decl.name runId repo >>= \case
    Left problem -> pure (Left (renderWorktreeError problem))
    Right worktree ->
      resolveProgram "git" >>= \case
        Nothing -> pure (Left "git is not on PATH")
        Just git ->
          pure
            ( Right
                ( LocalWorkspace
                    { stateDirectory,
                      agent = decl.name,
                      principal = compatibilityPrincipal decl.name,
                      repository = repo,
                      grant,
                      authority = runAuthority,
                      record,
                      tier = tierLabel,
                      launcher = hostProcessLauncher,
                      git
                    },
                  worktree
                )
            )

-- | The coding-agent runners of a worker: each step's grant, repository and
-- worktree are resolved from its input, and nothing is asked.
queuedCodingAgents :: LocalOperatorPaths -> ActionRecord -> [AgentDecl] -> CodingAgentRunners
queuedCodingAgents paths record agents CodingAgentStepInput {agent, parent, repository} =
  case filter (\decl -> decl.name == agent) agents of
    [] -> pure (Left (TierRefused ("agent " <> agentNameText agent <> " is not loaded by this worker")))
    decl : _
      | not (isJust (codingAgentAccessOf decl.behavior)) -> pure (Left (TierRefused ("agent " <> agentNameText agent <> " does not declare a coding agent")))
      | otherwise -> case repository of
          Nothing -> pure (Left (WorkspaceUnavailable "a queued coding-agent run names no repository; enqueue it with --workspace"))
          Just named -> do
            loaded <- loadLocalApprovals processCheckoutResolver paths.approvalsFile
            case loaded of
              Left problem -> pure (Left (WorkspaceUnavailable (renderApprovalsError problem)))
              Right approvals -> do
                selected <- selectRepository processCheckoutResolver approvals (repositorySelectorText named)
                store <- openGrantStore paths.stateDirectory
                let runId = WorkflowId parent
                    principal = compatibilityPrincipal decl.name
                case (selected, store) of
                  (Left problem, _) -> pure (Left (WorkspaceUnavailable (renderApprovalsError problem)))
                  (_, Left problem) -> pure (Left (WorkspaceUnavailable (Text.pack (show problem))))
                  (Right repo, Right grants) ->
                    resolveGrant Unattended approvals grants (recordGrantIn record principal (Just runId) decl.name) decl repo >>= \case
                      Left refusal -> pure (Left (TierRefused (renderGrantRefusal refusal)))
                      Right grant ->
                        openLocalRun paths.stateDirectory record decl (localRunAuthority record decl (Just runId) grant) grant repo runId >>= \case
                          Left problem -> pure (Left (WorkspaceUnavailable problem))
                          Right (local, _) -> do
                            launcher <- codingAgentLauncher
                            gate <- gateExecutable
                            pure (Right (localCodingAgentRunner LocalCodingAgentConfig {launcher, gate} local))

-- | A repository as a run names it: a @mori://@ identity, or a checkout path.
repositorySelectorText :: Text -> RepositorySelector
repositorySelectorText named
  | "mori://" `Text.isPrefixOf` named = SelectByIdentity (repositoryId named)
  | otherwise = SelectByPath (Text.unpack named)

-- | The @shikigami-agent-launch@ that mounts Baikai's CLI:
-- @SHIKIGAMI_AGENT_LAUNCH@, the executable beside this one, or @PATH@.
codingAgentLauncher :: IO FilePath
codingAgentLauncher = do
  configured <- lookupEnv "SHIKIGAMI_AGENT_LAUNCH"
  case configured of
    Just path -> pure path
    Nothing -> do
      self <- getExecutablePath
      let sibling = takeDirectory self </> "shikigami-agent-launch"
      exists <- doesFileExist sibling
      if exists then pure sibling else maybe "shikigami-agent-launch" id <$> findExecutable "shikigami-agent-launch"

-- | The @shikigami-local@ whose @gate@ command checks a coding agent's
-- shell and MCP calls: @SHIKIGAMI_LOCAL@, the executable beside this one,
-- or @PATH@.
gateExecutable :: IO FilePath
gateExecutable = siblingExecutable "SHIKIGAMI_LOCAL" "shikigami-local"

siblingExecutable :: String -> FilePath -> IO FilePath
siblingExecutable variable name = do
  configured <- lookupEnv variable
  case configured of
    Just path -> pure path
    Nothing -> do
      self <- getExecutablePath
      let sibling = takeDirectory self </> name
      exists <- doesFileExist sibling
      if exists then pure sibling else maybe name id <$> findExecutable name

-- | The authority of a declaration that requests nothing.
nothingGranted :: Authority
nothingGranted = authority DecidedByOperator \_ requested -> pure case requested of
  -- The run's report still reaches the operator's own state directory.
  EmitOutput kind _ | isLocalOutput kind -> Right Decision {action = requested, reference = "local-output", expiresAt = Nothing}
  _ -> Left (PolicyDenied (actionTag requested <> " is outside the grant: the declaration requests no capabilities"))

tierLabel :: TierLabel
tierLabel = trustTierLabel LocalOperator

-- | The principal the durable executor scopes an agent's tools by.
compatibilityPrincipal :: AgentName -> Principal
compatibilityPrincipal name = declarationCoordinate (either (const (agentNameText name)) id (identityText (compatibilityIdentity name)))

-- | The declared principal and the compatibility principal both act for
-- the agent: durable tools are scoped by the latter.
actingPrincipals :: AgentDecl -> Set.Set Principal
actingPrincipals AgentDecl {name, identity} =
  Set.fromList (compatibilityPrincipal name : [principal | Just IdentityDecl {principal} <- [identity]])
