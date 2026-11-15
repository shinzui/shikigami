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
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Shikigami.Agent.Capability.OneOff (oneOffCapabilityRuntime, renderOneOffCapabilityError)
import Shikigami.Agent.Capability.Workspace (renderWorkspaceError, resolveWorkspaceScope, workspaceReadDescriptor, workspaceReadProvider)
import Shikigami.Agent.Decl (AgentDecl (..), Behavior (..), Sink (..), codingAgentStepOf, requestedOverlays)
import Shikigami.App.Config (AppConfig (..))
import Shikigami.Authority
import Shikigami.Capability.Catalog (CapabilityResolutionError (..), ResolutionSubject, mkCapabilityCatalog)
import Shikigami.Capability.Declared (cliTools, mcpRequests)
import Shikigami.Capability.Declared.Catalog (ToolResolutionError (..), checkDeclaredTools, checkMcpRequests, defaultToolCatalogPath, loadToolCatalog, renderToolResolutionError)
import Shikigami.Capability.Declared.Local (CliToolHost (..), LocatedCliTool (..), cliToolProvider, locateCliTools)
import Shikigami.Capability.Mcp (McpBinding, McpToolRequest (..))
import Shikigami.Capability.Mcp.Local (mcpToolProvider)
import Shikigami.Capability.Overlay (CapabilityDescriptor (..), capabilityIdText)
import Shikigami.Capability.Provider (CapabilityProvider (..), CapabilityRuntime (..), installDurableAdapters, mkCapabilityProviderRegistry)
import Shikigami.CodingAgent.Local (LocalCodingAgentConfig (..), localCodingAgentRunner)
import Shikigami.CodingAgent.Workflow (refusingCodingAgentRunner)
import Shikigami.DeclaredTool.Local (localDeclaredToolRunner)
import Shikigami.DeclaredTool.Workflow (noDeclaredTools)
import Shikigami.Output (DefaultOutput (..), emptyOutputRegistry, mkOutputRegistry, renderOutputLoadError, validateOutputs)
import Shikigami.Output.Local (defaultLocalReport, localReportAdapter)
import Shikigami.Record (ActionRecord (..))
import Shikigami.Trust.LocalOperator.Approvals
import Shikigami.Trust.LocalOperator.Grant
import Shikigami.Trust.LocalOperator.Host (codingAgentLauncher, compatibilityPrincipal, gateExecutable, localRunAuthority, nothingGranted, openLocalRun, recordGrantIn, repositorySelectorText)
import Shikigami.Trust.Runtime
import Shikigami.Trust.Tier
import Shikigami.Workspace.Launch (worktreeRootPath)
import Shikigami.Workspace.Local.Adapters (LocalWorkspace (..), localWorkspaceAdapters, localWorkspaceDescriptors, localWorkspaceHost)
import Shikigami.Workspace.Local.Checkout (processCheckoutResolver)
import Shikigami.Workspace.Local.Launcher (hostProcessLauncher)
import Shikigami.Workspace.Local.Worktree (RunWorktree (..), releaseRunWorktree)
import System.FilePath ((</>))
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
    -- The local operator's reports go under the tier's state directory; a
    -- declaration with no outputs gets a Markdown report (EP-8 M2).
    localOutputs stateDirectory = either (error . Text.unpack) id (mkOutputRegistry [localReportAdapter (stateDirectory </> "reports")] (DefaultOutput defaultLocalReport))
    resolve subject@RunSubject {agent = decl, run, repository} = case config.trustTier of
      -- A declaration naming an output kind this composition does not
      -- register is refused before the run (EP-8 M2).
      LocalOperator
        | Left problems <- validateOutputs (localOutputs "/") decl.outputs -> pure (Left (CompositionFailed (Text.intercalate "; " (renderOutputLoadError <$> foldr (:) [] problems))))
        | otherwise -> resolveLocal subject
      _
        | Left problems <- validateOutputs emptyOutputRegistry decl.outputs -> pure (Left (CompositionFailed (Text.intercalate "; " (renderOutputLoadError <$> foldr (:) [] problems))))
      _ | not (null decl.tools) -> pure (Left (CompositionFailed (renderToolResolutionError (ToolsUnsupportedForTier (trustTierText config.trustTier)))))
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
                          outputs = emptyOutputRegistry,
                          declaredTools = noDeclaredTools,
                          release = pure ()
                        }
                  )

    resolveLocal RunSubject {agent = decl, principal, run, repository}
      | sinkKinds <- sinkKindNames decl, (first' : rest) <- sinkKinds = pure (Left (OutputsUnavailable (first' :| rest)))
      | null (requestedOverlays decl) && null decl.tools && not (isCodingAgent decl) =
          -- Nothing to grant: no repository is opened and every action is
          -- outside the (empty) grant.
          do
            stateDirectory <- maybe defaultStateDirectory pure config.localOperatorStateDirectory
            oneOffCapabilityRuntime Nothing decl >>= \case
              Left problem -> pure (Left (CompositionFailed (renderOneOffCapabilityError problem)))
              Right capabilities ->
                pure (Right TierRuntime {tier = LocalOperator, authority = scopeToRun run decl.name (recorded record tierLabel nothingGranted), record, capabilities, workspace = Nothing, grant = Nothing, codingAgents = refusingCodingAgentRunner containedCodingAgents, declaredTools = noDeclaredTools, outputs = localOutputs stateDirectory, release = pure ()})
      | otherwise =
          prepareDeclaredTools decl >>= \case
            Left problem -> pure (Left (CompositionFailed (renderToolResolutionError problem)))
            Right prepared -> resolveGranted prepared RunSubject {agent = decl, principal, run, repository}

    resolveGranted (located, servers) RunSubject {agent = decl, principal, run, repository} = do
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
                      done capabilities workspace runner steps release = Right TierRuntime {tier = LocalOperator, authority = runAuthority, record, capabilities, workspace, grant = Just grant, codingAgents = runner, declaredTools = steps, outputs = localOutputs stateDirectory, release}
                      toolsIn root =
                        (cliToolProvider CliToolHost {record, tier = tierLabel, agent = decl.name, root, launcher = hostProcessLauncher, host = "skill"} <$> located)
                          <> [mcpToolProvider record tierLabel decl.name root binding request.tools | (binding, request) <- servers]
                  if not (requestsMutation decl || isCodingAgent decl || runsToolSteps decl)
                    then
                      if null located && null servers
                        then
                          oneOffCapabilityRuntime (Just repo.source) decl <&> \case
                            Left problem -> Left (CompositionFailed (renderOneOffCapabilityError problem))
                            Right capabilities -> done capabilities Nothing (refusingCodingAgentRunner containedCodingAgents) noDeclaredTools (pure ())
                        else
                          readToolsRuntime repo.source (toolsIn repo.source) <&> \case
                            Left problem -> Left (CompositionFailed problem)
                            Right capabilities -> done capabilities Nothing (refusingCodingAgentRunner containedCodingAgents) noDeclaredTools (pure ())
                    else case run of
                      Nothing -> pure (Left (CompositionFailed "workspace.edit, workspace.exec, workspace.git and coding agents need a durable run; use shikigami-agent-run"))
                      Just runId ->
                        openLocalRun stateDirectory record decl runAuthority grant repo runId >>= \case
                          Left problem -> pure (Left (CompositionFailed problem))
                          Right (local, worktree) -> do
                            launcherPath <- codingAgentLauncher
                            gatePath <- gateExecutable
                            let runner = localCodingAgentRunner LocalCodingAgentConfig {launcher = launcherPath, gate = gatePath} local
                            localCapabilityRuntime (worktreeRootPath worktree.root) local (toolsIn (worktreeRootPath worktree.root)) <&> \case
                              Left problem -> Left (CompositionFailed problem)
                              Right capabilities -> done capabilities (Just (localWorkspaceHost local capabilities)) runner (\_ -> pure (Right (localDeclaredToolRunner gatePath local))) (releaseRunWorktree stateDirectory runId worktree)

containedCodingAgents :: Text
containedCodingAgents = "coding agents run only under trust.tier=local-operator until the batch qualification of ADR-40 passes"

isCodingAgent :: AgentDecl -> Bool
isCodingAgent AgentDecl {behavior} = isJust (codingAgentStepOf behavior)

-- | A flow with declared tools runs them as durable steps in the run's
-- worktree (EP-3 M4).
runsToolSteps :: AgentDecl -> Bool
runsToolSteps AgentDecl {behavior, tools} = case behavior of
  Flow {} -> not (null (cliTools tools))
  _ -> False

-- | Whether a declaration asks for a mutating workspace tool.
requestsMutation :: AgentDecl -> Bool
requestsMutation AgentDecl {capabilityOverlays} =
  any ((`elem` ["workspace.edit", "workspace.exec", "workspace.git"]) . capabilityIdText) capabilityOverlays

-- | @workspace.read@ scoped to the run's worktree, plus the local durable
-- adapters. The catalog admits exactly these descriptors; the run's authority
-- decides each call.
localCapabilityRuntime :: FilePath -> LocalWorkspace -> [CapabilityProvider] -> IO (Either Text CapabilityRuntime)
localCapabilityRuntime root local tools =
  resolveWorkspaceScope (Just root) <&> \case
    Left problem -> Left (renderWorkspaceError problem)
    Right scope -> do
      let descriptors = workspaceReadDescriptor : localWorkspaceDescriptors <> ((.descriptor) <$> tools)
      catalog <- first (Text.pack . show) (mkCapabilityCatalog descriptors)
      generic <- first (Text.pack . show) (mkCapabilityProviderRegistry (workspaceReadProvider scope : tools))
      providers <- first (Text.pack . show) (installDurableAdapters (localWorkspaceAdapters local) generic)
      Right CapabilityRuntime {catalog, providers, authorize = installedOnly descriptors}

-- | @workspace.read@ of the checkout plus the declared CLI tools, for a
-- declaration that edits nothing.
readToolsRuntime :: FilePath -> [CapabilityProvider] -> IO (Either Text CapabilityRuntime)
readToolsRuntime root tools =
  resolveWorkspaceScope (Just root) <&> \case
    Left problem -> Left (renderWorkspaceError problem)
    Right scope -> do
      let descriptors = workspaceReadDescriptor : ((.descriptor) <$> tools)
      catalog <- first (Text.pack . show) (mkCapabilityCatalog descriptors)
      providers <- first (Text.pack . show) (mkCapabilityProviderRegistry (workspaceReadProvider scope : tools))
      Right CapabilityRuntime {catalog, providers, authorize = installedOnly descriptors}

installedOnly :: [CapabilityDescriptor] -> ResolutionSubject -> CapabilityDescriptor -> Either CapabilityResolutionError ()
installedOnly descriptors _ descriptor
  | descriptor `elem` descriptors = Right ()
  | otherwise = Left (CapabilityAuthorizationDenied descriptor.capability "only the local workspace capabilities and declared tools are installed")

-- | The declaration's CLI tools, checked against any operator ceiling and
-- located on this host, before anything is granted or run.
prepareDeclaredTools :: AgentDecl -> IO (Either ToolResolutionError ([LocatedCliTool], [(McpBinding, McpToolRequest)]))
prepareDeclaredTools decl@AgentDecl {behavior}
  | null decl.tools = pure (Right ([], []))
  | Skill {} <- behavior = checkedTools
  | CodingAgent {} <- behavior =
      -- Checked and located now, rendered into the agent by its runner.
      fmap (const ([], [])) <$> checkedTools
  | Flow {} <- behavior =
      -- Checked and located now, run as durable steps by the flow.
      fmap (const ([], [])) <$> checkedTools
  | otherwise = pure (Left (ToolsUnsupportedForBehavior (behaviorName behavior)))
  where
    checkedTools = do
      catalog <- loadToolCatalog =<< defaultToolCatalogPath
      case catalog of
        Left problem -> pure (Left (ToolCatalogUnavailable problem))
        Right loaded -> case (checkDeclaredTools loaded (cliTools decl.tools), checkMcpRequests loaded (mcpRequests decl.tools)) of
          (Left problem, _) -> pure (Left problem)
          (_, Left problem) -> pure (Left problem)
          (Right (), Right servers) -> fmap (,servers) <$> locateCliTools (cliTools decl.tools)
    behaviorName = \case
      CodingAgent {} -> "CodingAgent"
      Flow {} -> "Flow"
      ShikumiProgram {} -> "ShikumiProgram"
      Deterministic {} -> "Deterministic"
      CoordinatingSkill {} -> "CoordinatingSkill"
      Skill {} -> "Skill"

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
