{-# LANGUAGE DataKinds #-}

-- | The trust-tier composition of the two light commands.
--
-- Under @contained@ and @multi-tenant@ each light command keeps what it does
-- today: the deny-all authority, the observation-only @workspace.read@
-- runtime and no workspace host. Under @local-operator@ the operator is the
-- authority: 'lightComposition' loads the approvals file, selects the
-- repository, resolves the declaration's grant (asking once in a terminal)
-- and installs the local authority over the action record (ADR-124).
module Shikigami.Agent.Trust
  ( WorkspaceArgument (..),
    parseWorkspaceArgument,
    workspaceSelector,
    workspaceArgumentText,
    lightComposition,
    terminalInteraction,
    compatibilityPrincipal,
  )
where

import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import Data.Functor ((<&>))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (getCurrentTime)
import Shikigami.Agent.Capability.OneOff (oneOffCapabilityRuntime, renderOneOffCapabilityError)
import Shikigami.Agent.Capability.Workspace (renderWorkspaceError, resolveWorkspaceScope, workspaceReadDescriptor, workspaceReadProvider)
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..), Sink (..), codingAgentStepOf)
import Shikigami.Agent.DeclarationValue (declarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (compatibilityIdentity, identityText)
import Shikigami.App.Config (AppConfig (..))
import Shikigami.Authority
import Shikigami.Capability.Catalog (CapabilityResolutionError (..), mkCapabilityCatalog)
import Shikigami.Capability.Overlay (CapabilityDescriptor (..), capabilityIdText)
import Shikigami.Capability.Provider (CapabilityRuntime (..), installDurableAdapters, mkCapabilityProviderRegistry)
import Shikigami.CodingAgent.Local (LocalCodingAgentConfig (..), localCodingAgentRunner)
import Shikigami.CodingAgent.Workflow (refusingCodingAgentRunner)
import Shikigami.Record (ActionRecord (..), RecordEvent (..), recordErrorText)
import Shikigami.Repository (repositoryId)
import Shikigami.Trust.LocalOperator.Approvals
import Shikigami.Trust.LocalOperator.Authority (LocalSelection (..), localOperatorAuthority)
import Shikigami.Trust.LocalOperator.Grant
import Shikigami.Trust.LocalOperator.Host (codingAgentLauncher, compatibilityPrincipal, localRunAuthority, nothingGranted, openLocalRun, recordGrantIn, repositorySelectorText)
import Shikigami.Trust.Runtime
import Shikigami.Trust.Tier
import Shikigami.Workspace.Launch (worktreeRootPath)
import Shikigami.Workspace.Local.Adapters (LocalWorkspace (..), localWorkspaceAdapters, localWorkspaceDescriptors, localWorkspaceHost)
import Shikigami.Workspace.Local.Checkout (processCheckoutResolver)
import Shikigami.Workspace.Local.Launcher (hostProcessLauncher)
import Shikigami.Workspace.Local.Worktree (RunWorktree (..), openRunWorktree, releaseRunWorktree, renderWorktreeError)
import System.Directory (doesFileExist, findExecutable)
import System.Environment (getExecutablePath, lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush, hIsTerminalDevice, stdin, stdout)
import System.IO.Error (isEOFError)

-- | How @--workspace@ names a repository: a @mori://@ identity or a path.
data WorkspaceArgument
  = WorkspacePath !FilePath
  | WorkspaceRepository !Text
  deriving stock (Eq, Show)

parseWorkspaceArgument :: String -> WorkspaceArgument
parseWorkspaceArgument raw
  | "mori://" `Text.isPrefixOf` Text.pack raw = WorkspaceRepository (Text.pack raw)
  | otherwise = WorkspacePath raw

workspaceSelector :: WorkspaceArgument -> RepositorySelector
workspaceSelector = repositorySelectorText . workspaceArgumentText

-- | How a run journals the repository it was given.
workspaceArgumentText :: WorkspaceArgument -> Text
workspaceArgumentText = \case
  WorkspacePath path -> Text.pack path
  WorkspaceRepository identity -> identity

-- | Ask on the terminal only when standard input and output are both
-- terminals and the caller did not pass @--no-confirm@.
terminalInteraction :: Bool -> IO Interaction
terminalInteraction noConfirm = do
  input <- hIsTerminalDevice stdin
  output <- hIsTerminalDevice stdout
  pure
    if noConfirm || not (input && output)
      then Unattended
      else Interactive \request -> do
        TextIO.putStr request
        TextIO.putStr "Grant this declaration? [y/N] "
        hFlush stdout
        -- End of input is a refusal, never a crash and never a yes.
        answer <- try TextIO.getLine
        pure case answer of
          Right line -> Text.toLower (Text.strip line) `elem` ["y", "yes"]
          Left (problem :: IOException) | isEOFError problem -> False
          Left _ -> False

-- | The composition of one light command invocation.
lightComposition :: AppConfig -> Interaction -> ActionRecord -> TierComposition
lightComposition config interaction record =
  TierComposition {tier = config.trustTier, resolve}
  where
    tierLabel = trustTierLabel config.trustTier
    resolve subject@RunSubject {agent = decl, run, repository} = case config.trustTier of
      LocalOperator -> resolveLocal subject
      _ -> do
        workspace <- sequence <$> traverse (selectRepository processCheckoutResolver emptyApprovals) repository
        case workspace of
          Left problem -> pure (Left (RepositoryUnavailable problem))
          Right selected ->
            oneOffCapabilityRuntime ((.source) <$> selected) decl >>= \case
              Left problem -> pure (Left (CompositionFailed (renderOneOffCapabilityError problem)))
              Right capabilities ->
                pure
                  ( Right
                      TierRuntime
                        { tier = config.trustTier,
                          authority = scopeToRun run decl.name (recorded record tierLabel denyAll),
                          record,
                          capabilities,
                          workspace = Nothing,
                          grant = Nothing,
                          codingAgents = refusingCodingAgentRunner containedCodingAgents,
                          release = pure ()
                        }
                  )

    resolveLocal RunSubject {agent = decl, principal, run, repository}
      | sinkKinds <- sinkKindNames decl, (first' : rest) <- sinkKinds = pure (Left (OutputsUnavailable (first' :| rest)))
      | null decl.capabilityOverlays && not (isCodingAgent decl) =
          -- Nothing to grant: no repository is opened and every action is
          -- outside the (empty) grant.
          oneOffCapabilityRuntime Nothing decl >>= \case
            Left problem -> pure (Left (CompositionFailed (renderOneOffCapabilityError problem)))
            Right capabilities ->
              pure (Right TierRuntime {tier = LocalOperator, authority = scopeToRun run decl.name (recorded record tierLabel nothingGranted), record, capabilities, workspace = Nothing, grant = Nothing, codingAgents = refusingCodingAgentRunner containedCodingAgents, release = pure ()})
      | otherwise = do
          approvalsPath <- maybe defaultApprovalsPath pure config.localOperatorApprovalsFile
          stateDirectory <- maybe defaultStateDirectory pure config.localOperatorStateDirectory
          loaded <- loadLocalApprovals processCheckoutResolver approvalsPath
          case loaded of
            Left problem -> pure (Left (RepositoryUnavailable problem))
            Right approvals -> do
              selected <- selectRepository processCheckoutResolver approvals (maybe (SelectByPath ".") id repository)
              store <- openGrantStore stateDirectory
              case (selected, store) of
                (Left problem, _) -> pure (Left (RepositoryUnavailable problem))
                (_, Left problem) -> pure (Left (CompositionFailed (Text.pack (show problem))))
                (Right repo, Right grants) ->
                  resolveGrant interaction approvals grants (recordGrantIn record principal run decl.name) decl repo >>= \case
                    Left refusal -> pure (Left (NoGrant refusal))
                    Right grant -> do
                      let runAuthority = localRunAuthority record decl run grant
                          done capabilities workspace runner release = Right TierRuntime {tier = LocalOperator, authority = runAuthority, record, capabilities, workspace, grant = Just grant, codingAgents = runner, release}
                      if not (requestsMutation decl || isCodingAgent decl)
                        then
                          oneOffCapabilityRuntime (Just repo.source) decl <&> \case
                            Left problem -> Left (CompositionFailed (renderOneOffCapabilityError problem))
                            Right capabilities -> done capabilities Nothing (refusingCodingAgentRunner containedCodingAgents) (pure ())
                        else case run of
                          Nothing -> pure (Left (CompositionFailed "workspace.edit, workspace.exec, workspace.git and coding agents need a durable run; use shikigami-agent-run"))
                          Just runId ->
                            openLocalRun stateDirectory record decl runAuthority grant repo runId >>= \case
                              Left problem -> pure (Left (CompositionFailed problem))
                              Right (local, worktree) -> do
                                launcherPath <- codingAgentLauncher
                                let runner = localCodingAgentRunner LocalCodingAgentConfig {launcher = launcherPath} local
                                localCapabilityRuntime (worktreeRootPath worktree.root) local <&> \case
                                  Left problem -> Left (CompositionFailed problem)
                                  Right capabilities -> done capabilities (Just (localWorkspaceHost local capabilities)) runner (releaseRunWorktree stateDirectory runId worktree)

containedCodingAgents :: Text
containedCodingAgents = "coding agents run only under trust.tier=local-operator until the batch qualification of ADR-40 passes"

isCodingAgent :: AgentDecl -> Bool
isCodingAgent AgentDecl {behavior} = isJust (codingAgentStepOf behavior)

-- | Whether a declaration asks for a mutating workspace tool.
requestsMutation :: AgentDecl -> Bool
requestsMutation AgentDecl {capabilityOverlays} =
  any ((`elem` ["workspace.edit", "workspace.exec", "workspace.git"]) . capabilityIdText) capabilityOverlays

-- | @workspace.read@ scoped to the run's worktree, plus the local durable
-- adapters. The catalog admits exactly these descriptors; the run's authority
-- decides each call.
localCapabilityRuntime :: FilePath -> LocalWorkspace -> IO (Either Text CapabilityRuntime)
localCapabilityRuntime root local =
  resolveWorkspaceScope (Just root) <&> \case
    Left problem -> Left (renderWorkspaceError problem)
    Right scope -> do
      let descriptors = workspaceReadDescriptor : localWorkspaceDescriptors
      catalog <- first (Text.pack . show) (mkCapabilityCatalog descriptors)
      generic <- first (Text.pack . show) (mkCapabilityProviderRegistry [workspaceReadProvider scope])
      providers <- first (Text.pack . show) (installDurableAdapters (localWorkspaceAdapters local) generic)
      Right
        CapabilityRuntime
          { catalog,
            providers,
            authorize = \_ descriptor ->
              if descriptor `elem` descriptors
                then Right ()
                else Left (CapabilityAuthorizationDenied descriptor.capability "only the local workspace capabilities are installed")
          }

-- | The output kinds a declaration's sinks would deliver through.
sinkKindNames :: AgentDecl -> [Text]
sinkKindNames AgentDecl {sinks} = kindName <$> sinks
  where
    kindName = \case
      KawaDigest {} -> "kawa.digest"
      KizashiSignal {} -> "kizashi.signal"
      ReiAction {} -> "rei.action"
      DanwaConversation {} -> "danwa.conversation"
      ChannelEgress {} -> "channel.egress"
