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
    lightComposition,
    terminalInteraction,
    compatibilityPrincipal,
  )
where

import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Time (getCurrentTime)
import Shikigami.Agent.Capability.OneOff (oneOffCapabilityRuntime, renderOneOffCapabilityError)
import Shikigami.Agent.Checkout (processCheckoutResolver)
import Shikigami.Agent.Decl (AgentDecl (..), IdentityDecl (..), Sink (..))
import Shikigami.Agent.DeclarationValue (declarationCoordinate, declarationCoordinateText)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Agent.Principal (compatibilityIdentity, identityText)
import Shikigami.App.Config (AppConfig (..))
import Shikigami.Authority
import Shikigami.Record (ActionRecord (..), RecordEvent (..), recordErrorText)
import Shikigami.Repository (repositoryId)
import Shikigami.Trust.LocalOperator.Approvals
import Shikigami.Trust.LocalOperator.Authority (LocalSelection (..), localOperatorAuthority)
import Shikigami.Trust.LocalOperator.Grant
import Shikigami.Trust.Runtime
import Shikigami.Trust.Tier
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
workspaceSelector = \case
  WorkspacePath path -> SelectByPath path
  WorkspaceRepository identity -> SelectByIdentity (repositoryId identity)

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

-- | The principal the durable executor scopes an agent's tools by.
compatibilityPrincipal :: AgentName -> Principal
compatibilityPrincipal name = declarationCoordinate (either (const (agentNameText name)) id (identityText (compatibilityIdentity name)))

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
                          grant = Nothing
                        }
                  )

    resolveLocal RunSubject {agent = decl, principal, run, repository}
      | sinkKinds <- sinkKindNames decl, (first' : rest) <- sinkKinds = pure (Left (OutputsUnavailable (first' :| rest)))
      | null decl.capabilityOverlays =
          -- Nothing to grant: no repository is opened and every action is
          -- outside the (empty) grant.
          oneOffCapabilityRuntime Nothing decl >>= \case
            Left problem -> pure (Left (CompositionFailed (renderOneOffCapabilityError problem)))
            Right capabilities ->
              pure (Right TierRuntime {tier = LocalOperator, authority = scopeToRun run decl.name (recorded record tierLabel nothingGranted), record, capabilities, grant = Nothing})
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
                  resolveGrant interaction approvals grants (recordGrant principal run decl.name) decl repo >>= \case
                    Left refusal -> pure (Left (NoGrant refusal))
                    Right grant ->
                      oneOffCapabilityRuntime (Just repo.source) decl >>= \case
                        Left problem -> pure (Left (CompositionFailed (renderOneOffCapabilityError problem)))
                        Right capabilities -> do
                          let selection = LocalSelection {agent = decl.name, principals = actingPrincipals decl, grant}
                          pure
                            ( Right
                                TierRuntime
                                  { tier = LocalOperator,
                                    authority = scopeToRun run decl.name (recorded record tierLabel (localOperatorAuthority selection)),
                                    record,
                                    capabilities,
                                    grant = Just grant
                                  }
                            )

    recordGrant principal run agentName grant = do
      at <- getCurrentTime
      case grantEntry grant of
        Left problem -> pure (Left problem)
        Right entry ->
          first recordErrorText
            <$> record.append RecordEvent {at, run, principal = declarationCoordinateText principal, tier = tierLabel, agent = Just agentName, entry}

    nothingGranted = authority DecidedByOperator \_ requested ->
      pure (Left (PolicyDenied (actionTag requested <> " is outside the grant: the declaration requests no capabilities")))

-- | The declared principal and the compatibility principal both act for
-- the agent: durable tools are scoped by the latter.
actingPrincipals :: AgentDecl -> Set.Set Principal
actingPrincipals AgentDecl {name, identity} =
  Set.fromList (compatibilityPrincipal name : [principal | Just IdentityDecl {principal} <- [identity]])

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
