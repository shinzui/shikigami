-- | What the local operator granted one declaration on one repository.
--
-- A grant has two sources, which yield the same sealed 'LocalGrant': an
-- explicit entry in the approvals file, or a one-time confirmation in a
-- terminal stored under the digest of the declaration and the repository
-- (ADR-124). The store lives under the operator's state directory, outside
-- every workspace, so an agent cannot write its own grant, and an edited
-- declaration asks again because its digest changes.
module Shikigami.Trust.LocalOperator.Grant
  ( -- * Requests
    GrantRequest (..),
    requestedGrant,
    proposeBudget,
    renderGrantRequest,

    -- * Grants
    GrantDigest,
    grantDigest,
    grantDigestText,
    shortDigest,
    GrantSource (..),
    LocalGrant,
    grantEntry,

    -- * The store
    GrantStore (..),
    GrantError (..),
    openGrantStore,
    defaultStateDirectory,

    -- * Resolution
    Interaction (..),
    GrantRefusal (..),
    renderGrantRefusal,
    resolveGrant,
    grantsForAgent,
  )
where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON, ToJSON, Value, object, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isSuffixOf)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
import GHC.Records (HasField (..))
import Shikigami.Agent.Decl (AgentDecl (..), codingAgentStepOf, declaredToolCapabilities, requestedOverlays)
import Shikigami.Agent.Name (AgentName, agentNameText, mkAgentName)
import Shikigami.Capability.Declared (cliTools, mcpRequests, renderCliToolDecl)
import Shikigami.Capability.Mcp (McpToolRequest (..), mcpServerIdText, mcpToolNameText)
import Shikigami.Capability.Overlay (CapabilityId, capabilityIdText, mkCapabilityId)
import Shikigami.CodingAgent.Types (CodingAgentStep (..), accessText, providerText)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Record (RecordEntry, mkRecordEntry, mkRecordKind, recordErrorText)
import Shikigami.Repository (RepositoryId, repositoryId, repositoryIdText)
import Shikigami.Trust.LocalOperator.Approvals
import System.Directory (XdgDirectory (XdgState), createDirectoryIfMissing, doesFileExist, getXdgDirectory, listDirectory, removeFile, renameFile)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

-- | What a declaration asks for on a repository. Pure, derived from the
-- declaration; the budget is what a confirmation would grant.
data GrantRequest = GrantRequest
  { agent :: !AgentName,
    repository :: !LocalRepository,
    placement :: !WorkspacePlacement,
    capabilities :: !(Set CapabilityId),
    -- | The vendor coding tool and access a @CodingAgent@ declaration asks
    -- to launch.
    codingAgent :: !(Maybe (Text, Text)),
    -- | Each declared CLI tool, rendered with its executable and patterns.
    tools :: ![Text],
    budget :: !Budget
  }
  deriving stock (Eq, Show)

requestedGrant :: AgentDecl -> LocalRepository -> GrantRequest
requestedGrant decl@AgentDecl {name, behavior, tools} repository =
  GrantRequest
    { agent = name,
      repository,
      placement = repository.placement,
      capabilities = Set.fromList (requestedOverlays decl <> declaredToolCapabilities decl),
      codingAgent = (\step -> (providerText step.provider, accessText step.access)) <$> codingAgentStepOf behavior,
      tools = (renderCliToolDecl <$> cliTools tools) <> [mcpServerIdText request.server <> " (MCP): " <> Text.intercalate ", " (mcpToolNameText <$> foldr (:) [] request.tools) | request <- mcpRequests tools],
      budget = defaultBudget
    }

-- | Show and grant a caller's own bounded budget instead of 'defaultBudget'.
proposeBudget :: Budget -> GrantRequest -> GrantRequest
proposeBudget proposed GrantRequest {agent, repository, placement, capabilities, codingAgent, tools} = GrantRequest {agent, repository, placement, capabilities, codingAgent, tools, budget = proposed}

renderGrantRequest :: GrantRequest -> Text
renderGrantRequest GrantRequest {agent, repository, placement, capabilities, codingAgent, tools, budget = Budget {modelAttempts, toolAttempts, tokens, minutes}} =
  Text.unlines
    ( [ "local-operator: " <> agentNameText agent <> " asks for",
        "  repository   " <> repositoryIdText repository.identity <> " (" <> Text.pack repository.source <> ")",
        "  placement    " <> placementText placement
      ]
        <> maybe [] (\(provider, access) -> ["  coding agent " <> provider <> " with " <> access <> " access, unattended"]) codingAgent
        <> (("  tool         " <>) <$> tools)
        <> [ "  capabilities " <> if Set.null capabilities then "none" else Text.intercalate ", " (capabilityIdText <$> Set.toList capabilities),
             "  budget       "
               <> Text.pack (show modelAttempts)
               <> " model attempts, "
               <> Text.pack (show toolAttempts)
               <> " tool attempts, "
               <> Text.pack (show tokens)
               <> " tokens, "
               <> Text.pack (show minutes)
               <> " minutes"
           ]
    )

-- | @versionedDigest "shikigami.local-grant/1"@ over the declaration's
-- journal JSON and the repository identity.
newtype GrantDigest = GrantDigest Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

grantDigest :: AgentDecl -> LocalRepository -> GrantDigest
grantDigest decl repository =
  GrantDigest (Text.replace ":" "-" (versionedDigest "shikigami.local-grant/1" (Aeson.toJSON decl, repositoryIdText repository.identity)))

grantDigestText :: GrantDigest -> Text
grantDigestText (GrantDigest value) = value

-- | The first twelve hex digits, for display and @shikigami-local revoke@.
shortDigest :: GrantDigest -> Text
shortDigest (GrantDigest value) = Text.take 12 (Text.drop 1 (Text.dropWhile (/= '-') value))

data GrantSource
  = FromApprovalsFile
  | ConfirmedByOperator !UTCTime
  deriving stock (Eq, Show)

-- | A sealed grant. Read it through its views: @agent@, @repository@,
-- @source@ (the checkout), @placement@, @capabilities@, @rules@, @budget@,
-- @grantedBy@ and @digest@.
-- Positional so that only this module builds a grant; the views below are
-- the read interface.
data LocalGrant
  = LocalGrant
      !AgentName
      !RepositoryId
      !FilePath
      !WorkspacePlacement
      !(Set CapabilityId)
      ![ApprovedRule]
      !Budget
      !GrantSource
      !GrantDigest
  deriving stock (Eq, Show)

instance HasField "agent" LocalGrant AgentName where getField (LocalGrant agent _ _ _ _ _ _ _ _) = agent

instance HasField "repository" LocalGrant RepositoryId where getField (LocalGrant _ repository _ _ _ _ _ _ _) = repository

instance HasField "source" LocalGrant FilePath where getField (LocalGrant _ _ checkout _ _ _ _ _ _) = checkout

instance HasField "placement" LocalGrant WorkspacePlacement where getField (LocalGrant _ _ _ placement _ _ _ _ _) = placement

instance HasField "capabilities" LocalGrant (Set CapabilityId) where getField (LocalGrant _ _ _ _ capabilities _ _ _ _) = capabilities

instance HasField "rules" LocalGrant [ApprovedRule] where getField (LocalGrant _ _ _ _ _ rules _ _ _) = rules

instance HasField "budget" LocalGrant Budget where getField (LocalGrant _ _ _ _ _ _ budget _ _) = budget

instance HasField "grantedBy" LocalGrant GrantSource where getField (LocalGrant _ _ _ _ _ _ _ grantedBy _) = grantedBy

instance HasField "digest" LocalGrant GrantDigest where getField (LocalGrant _ _ _ _ _ _ _ _ digest) = digest

-- | The @authority.granted@ record entry for a grant. It names the digest,
-- the repository, the capabilities and the budget, never a rule's arguments.
grantEntry :: LocalGrant -> Either Text RecordEntry
grantEntry grant = do
  kind <- mkRecordKind "authority.granted"
  first recordErrorText (mkRecordEntry kind (storedJson grant))

storedJson :: LocalGrant -> Value
storedJson (LocalGrant grantAgent grantRepository grantCheckout grantPlacement grantCapabilities grantRules grantBudget grantSource grantDigestValue) =
  object
    [ "digest" .= grantDigestValue,
      "agent" .= agentNameText grantAgent,
      "repository" .= repositoryIdText grantRepository,
      "checkout" .= grantCheckout,
      "placement" .= grantPlacement,
      "capabilities" .= (capabilityIdText <$> Set.toList grantCapabilities),
      "rules" .= ((\rule -> ruleNameText rule.name) <$> grantRules),
      "budget" .= grantBudget,
      "grantedBy" .= case grantSource of
        FromApprovalsFile -> "approvals-file" :: Text
        ConfirmedByOperator _ -> "operator-confirmation",
      "confirmedAt" .= case grantSource of
        FromApprovalsFile -> Nothing
        ConfirmedByOperator at -> Just at
    ]

data StoredGrant = StoredGrant
  { digest :: !Text,
    agent :: !Text,
    repository :: !Text,
    checkout :: !FilePath,
    placement :: !WorkspacePlacement,
    capabilities :: ![Text],
    budget :: !Budget,
    confirmedAt :: !UTCTime
  }
  deriving stock (Generic)

instance FromJSON StoredGrant where
  parseJSON = Aeson.withObject "StoredGrant" \value ->
    StoredGrant
      <$> value .: "digest"
      <*> value .: "agent"
      <*> value .: "repository"
      <*> value .: "checkout"
      <*> value .: "placement"
      <*> value .: "capabilities"
      <*> value .: "budget"
      <*> value .: "confirmedAt"

data GrantError
  = GrantStoreUnavailable !Text
  | GrantFileInvalid !FilePath !Text
  deriving stock (Eq, Show)

-- | Confirmed grants, one JSON file per digest, mode 0600, under a 0700
-- directory.
data GrantStore = GrantStore
  { lookup :: !(GrantDigest -> IO (Either GrantError (Maybe LocalGrant))),
    save :: !(LocalGrant -> IO (Either GrantError ())),
    list :: !(IO (Either GrantError [LocalGrant])),
    revoke :: !(Text -> IO (Either GrantError [GrantDigest]))
  }

-- | @$XDG_STATE_HOME/shikigami@: grants, worktrees, locks and the one-off
-- record live here.
defaultStateDirectory :: IO FilePath
defaultStateDirectory = getXdgDirectory XdgState "shikigami"

openGrantStore :: FilePath -> IO (Either GrantError GrantStore)
openGrantStore stateDirectory = do
  let directory = stateDirectory </> "grants"
  prepared <- try do
    createDirectoryIfMissing True directory
    setFileMode directory 0o700
  pure case prepared of
    Left (problem :: IOException) -> Left (GrantStoreUnavailable (Text.pack (show problem)))
    Right () ->
      Right
        GrantStore
          { lookup = \(GrantDigest value) -> do
              let path = directory </> (Text.unpack value <> ".json")
              exists <- doesFileExist path
              if exists then fmap Just <$> readGrant path else pure (Right Nothing),
            save = \grant -> do
              let GrantDigest value = grant.digest
                  path = directory </> (Text.unpack value <> ".json")
                  temporary = path <> ".tmp"
              written <- try do
                LazyByteString.writeFile temporary (Aeson.encode (storedJson grant))
                setFileMode temporary 0o600
                renameFile temporary path
              pure (first (\(problem :: IOException) -> GrantStoreUnavailable (Text.pack (show problem))) written),
            list = do
              entries <- try (listDirectory directory)
              case entries of
                Left (problem :: IOException) -> pure (Left (GrantStoreUnavailable (Text.pack (show problem))))
                Right names -> sequence <$> mapM (readGrant . (directory </>)) (filter (".json" `isSuffixOf`) names),
            revoke = \prefix -> do
              entries <- try (listDirectory directory)
              case entries of
                Left (problem :: IOException) -> pure (Left (GrantStoreUnavailable (Text.pack (show problem))))
                Right names -> do
                  let matching = [name | name <- names, ".json" `isSuffixOf` name, prefix `Text.isInfixOf` Text.pack name, Text.length prefix >= 8]
                  mapM_ (removeFile . (directory </>)) matching
                  pure (Right (GrantDigest . Text.dropEnd 5 . Text.pack <$> matching))
          }
  where
    readGrant path = do
      contents <- try (LazyByteString.readFile path)
      pure case contents of
        Left (problem :: IOException) -> Left (GrantStoreUnavailable (Text.pack (show problem)))
        Right bytes -> case Aeson.eitherDecode bytes of
          Left detail -> Left (GrantFileInvalid path (Text.pack detail))
          Right stored -> fromStored path stored
    fromStored path StoredGrant {digest, agent, repository, checkout, placement, capabilities, budget, confirmedAt} =
      first (GrantFileInvalid path) do
        agentName <- either Left Right (mkAgentNameText agent)
        ids <- traverse (first (Text.pack . show) . mkCapabilityId) capabilities
        pure (LocalGrant agentName (repositoryId repository) checkout placement (Set.fromList ids) [] budget (ConfirmedByOperator confirmedAt) (GrantDigest digest))
    mkAgentNameText = mkAgentName

-- | Whether the command may ask. Only a command whose standard input and
-- output are both terminals, and which was not given @--no-confirm@, asks.
data Interaction
  = Interactive !(Text -> IO Bool)
  | Unattended

data GrantRefusal
  = -- | Nothing granted this declaration on this repository and the command
    -- could not ask.
    NoStoredGrant !GrantDigest
  | OperatorDeclined
  | -- | The approvals-file entry does not list these requested capabilities.
    RequestExceedsApproval !(Set CapabilityId)
  | GrantUnavailable !Text
  deriving stock (Eq, Show)

renderGrantRefusal :: GrantRefusal -> Text
renderGrantRefusal = \case
  NoStoredGrant _ -> "no stored grant for this declaration; run it once in a terminal to confirm it"
  OperatorDeclined -> "the operator declined the grant"
  RequestExceedsApproval missing -> "the declaration requests capabilities its approval does not list: " <> Text.intercalate ", " (capabilityIdText <$> Set.toList missing)
  GrantUnavailable detail -> "the grant could not be read or recorded: " <> detail

-- | Resolve the grant of a declaration on a repository, in order: an
-- approvals-file entry (never prompted); a stored confirmation under the
-- declaration's digest; a confirmation asked now when 'Interactive', which is
-- recorded (through the supplied recorder, before it is stored) and saved; or
-- 'NoStoredGrant'.
resolveGrant ::
  Interaction ->
  LocalApprovals ->
  GrantStore ->
  (LocalGrant -> IO (Either Text ())) ->
  AgentDecl ->
  LocalRepository ->
  IO (Either GrantRefusal LocalGrant)
resolveGrant interaction approvals store recordGrant decl repository =
  case approvalFor approvals request.agent repository of
    Just approval -> do
      let missing = request.capabilities `Set.difference` approval.capabilities
      pure
        if Set.null missing
          then Right (fromApproval approval)
          else Left (RequestExceedsApproval missing)
    Nothing ->
      store.lookup digest >>= \case
        Left problem -> pure (Left (GrantUnavailable (renderGrantError problem)))
        Right (Just stored) -> pure (Right stored)
        Right Nothing -> case interaction of
          Unattended -> pure (Left (NoStoredGrant digest))
          Interactive ask -> do
            accepted <- ask (renderGrantRequest request)
            if not accepted
              then pure (Left OperatorDeclined)
              else do
                now <- getCurrentTime
                let grant = confirmed now
                recordGrant grant >>= \case
                  Left problem -> pure (Left (GrantUnavailable problem))
                  Right () -> either (Left . GrantUnavailable . renderGrantError) (const (Right grant)) <$> store.save grant
  where
    request = requestedGrant decl repository
    digest = grantDigest decl repository
    fromApproval approval =
      LocalGrant request.agent repository.identity repository.source repository.placement approval.capabilities approval.rules (maybe defaultBudget id approval.budget) FromApprovalsFile digest
    confirmed now =
      LocalGrant request.agent repository.identity repository.source request.placement request.capabilities [] request.budget (ConfirmedByOperator now) digest

renderGrantError :: GrantError -> Text
renderGrantError = \case
  GrantStoreUnavailable detail -> detail
  GrantFileInvalid path detail -> Text.pack path <> ": " <> detail

-- | Every stored grant of one agent. A scheduled run carries no repository,
-- so its composition takes the repository from the agent's single grant.
grantsForAgent :: GrantStore -> AgentName -> IO (Either GrantError [LocalGrant])
grantsForAgent store agent = fmap (filter (\grant -> grant.agent == agent)) <$> store.list
