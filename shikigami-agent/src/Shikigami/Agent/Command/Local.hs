-- | @shikigami-local@: the local operator's view of what they granted and
-- what their agents did (ADR-124).
--
-- @approvals@ validates the explicit approvals file and lists its
-- repositories and approvals beside every stored confirmation. @revoke@
-- deletes a stored confirmation, so the next interactive run asks again.
-- @ledger@ prints the action record, the single record of every grant and
-- decision in the stock composition.
module Shikigami.Agent.Command.Local
  ( LocalCommand (..),
    LedgerOptions (..),
    runLocal,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Text.IO qualified as TextIO
import Data.Time.Format.ISO8601 (iso8601Show)
import Keiro.Workflow (WorkflowId (..))
import Kiroku.Store.Connection (KirokuStore (..), defaultConnectionSettings, withStore)
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (agentNameText)
import Shikigami.App.Config (AppConfig (..), revealSecretText)
import Shikigami.App.Config.Load (requireDatabaseUrl)
import Shikigami.Capability.Declared (CliToolDecl (..), cliCapabilityName, cliTools, renderCliToolDecl, toolNameText)
import Shikigami.Capability.Declared.Catalog (CliToolCeiling (..), ToolCatalog (..), checkDeclaredTools, defaultToolCatalogPath, loadToolCatalog, renderToolResolutionError)
import Shikigami.Capability.Declared.Local (LocatedCliTool (..), locateCliTools)
import Shikigami.Capability.Mcp (DiscoveredMcpTool (..), DiscoveryStatus (..), McpBinding (..), discoveryStatus, mkMcpServerId)
import Shikigami.Capability.Mcp.Local (McpSession (..), mcpBindingRevision, openMcpSession)
import Shikigami.Capability.Overlay (CapabilityDescriptor (..), capabilityIdText, capabilityRevisionText)
import Shikigami.Migrations (verifyShikigamiMigrations)
import Shikigami.Record
import Shikigami.Repository (repositoryId, repositoryIdText)
import Shikigami.Trust.LocalOperator.Approvals
import Shikigami.Trust.LocalOperator.Grant
import Shikigami.Workspace.Local.Checkout (processCheckoutResolver)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hPutStrLn, stderr)

data LocalCommand
  = ShowApprovals
  | RevokeGrant !Text
  | Ledger !LedgerOptions
  | -- | A declaration file and the repository it would run in.
    CheckTools !FilePath !(Maybe FilePath)
  | -- | Connect to a bound MCP server and list its tools against the binding.
    DiscoverMcp !Text !(Maybe FilePath)

data LedgerOptions = LedgerOptions
  { run :: !(Maybe Text),
    refusals :: !Bool,
    limit :: !(Maybe Int),
    json :: !Bool
  }

runLocal :: LocalCommand -> AppConfig -> IO ()
runLocal command config = case command of
  ShowApprovals -> do
    path <- maybe defaultApprovalsPath pure config.localOperatorApprovalsFile
    approvals <- loadLocalApprovals processCheckoutResolver path >>= either (die . renderApprovalsError) pure
    TextIO.putStrLn ("approvals file " <> Text.pack path)
    mapM_ (TextIO.putStrLn . renderRepository) approvals.repositories
    mapM_ (TextIO.putStrLn . renderApproval) approvals.approvals
    store <- stateStore
    grants <- store.list >>= either (die . Text.pack . show) pure
    if null grants then putStrLn "no stored grants" else mapM_ (TextIO.putStrLn . renderGrant) grants
  RevokeGrant prefix -> do
    store <- stateStore
    removed <- store.revoke prefix >>= either (die . Text.pack . show) pure
    case removed of
      [] -> die ("no stored grant matches " <> prefix <> " (give at least eight characters of its digest)")
      digests -> mapM_ (\digest -> TextIO.putStrLn ("revoked " <> grantDigestText digest)) digests
  Ledger LedgerOptions {run, refusals, limit, json} -> do
    recordLimit <- either die pure (maybe (Right defaultRecordLimit) mkRecordLimit limit)
    connection <- revealSecretText <$> requireDatabaseUrl "shikigami-local ledger" config
    verifyShikigamiMigrations connection
    withStore (defaultConnectionSettings connection) \KirokuStore {pool} ->
      readRecord pool RecordQuery {run = WorkflowId <$> run, kinds = if refusals then RefusalsOnly else AllKinds, limit = recordLimit} >>= \case
        Left problem -> die (recordErrorText problem)
        Right [] | not json -> putStrLn "no record events"
        Right events
          | json -> mapM_ (LazyChar8.putStrLn . Aeson.encode) events
          | otherwise -> mapM_ (TextIO.putStrLn . renderRecordEvent) events
  CheckTools path workspace -> do
    decl <- loadAgent path >>= either (die . Text.pack . show) pure
    let declared = cliTools decl.tools
    if null declared then putStrLn "the declaration declares no tools" else pure ()
    catalogPath <- defaultToolCatalogPath
    catalog <- loadToolCatalog catalogPath >>= either die pure
    checked <- case checkDeclaredTools catalog declared of
      Left problem -> pure (Left problem)
      Right () -> locateCliTools declared
    case checked of
      Left problem -> TextIO.putStrLn ("refused: " <> renderToolResolutionError problem) >> exitWith (ExitFailure 1)
      Right located -> do
        approvalsPath <- maybe defaultApprovalsPath pure config.localOperatorApprovalsFile
        approvals <- loadLocalApprovals processCheckoutResolver approvalsPath >>= either (die . renderApprovalsError) pure
        repository <- selectRepository processCheckoutResolver approvals (maybe (SelectByPath ".") repositorySelector workspace) >>= either (die . renderApprovalsError) pure
        store <- stateStore
        granted <- resolveGrant Unattended approvals store (\_ -> pure (Right ())) decl repository
        let status = case granted of
              Right _ -> "granted"
              Left (NoStoredGrant _) -> "needs confirmation"
              Left refusal -> "refused: " <> renderGrantRefusal refusal
            bounded tool = if any (\bound -> bound.name == tool.name) catalog.cli then "bounded by " <> Text.pack catalogPath else "no ceiling"
        mapM_
          ( \LocatedCliTool {decl = tool, program, descriptor} ->
              TextIO.putStrLn
                ( status
                    <> "  "
                    <> cliCapabilityName tool.name
                    <> "  "
                    <> programPathText program
                    <> "  "
                    <> capabilityRevisionText descriptor.revision
                    <> "  overlay__cli-"
                    <> toolNameText tool.name
                    <> "__run  "
                    <> bounded tool
                    <> "\n    "
                    <> renderCliToolDecl tool
                )
          )
          located
        case granted of
          Right _ -> pure ()
          Left (NoStoredGrant _) -> exitWith (ExitFailure 3)
          Left _ -> exitWith (ExitFailure 1)
  DiscoverMcp serverName workspace -> do
    catalogPath <- defaultToolCatalogPath
    catalog <- loadToolCatalog catalogPath >>= either die pure
    server <- either die pure (mkMcpServerId serverName)
    binding <- maybe (die ("no MCP server " <> serverName <> " is bound in " <> Text.pack catalogPath)) pure (find (\candidate -> candidate.server == server) catalog.mcp)
    approvalsPath <- maybe defaultApprovalsPath pure config.localOperatorApprovalsFile
    approvals <- loadLocalApprovals processCheckoutResolver approvalsPath >>= either (die . renderApprovalsError) pure
    repository <- selectRepository processCheckoutResolver approvals (maybe (SelectByPath ".") repositorySelector workspace) >>= either (die . renderApprovalsError) pure
    session <- openMcpSession repository.source binding >>= either die pure
    TextIO.putStrLn ("mcp." <> serverName <> " in " <> Text.pack repository.source <> " (revision " <> capabilityRevisionText (mcpBindingRevision binding) <> ")")
    mapM_
      ( \offered -> do
          let status = discoveryStatus binding offered
          TextIO.putStrLn ("  " <> offered.name <> "  " <> case status of Approved -> "approved"; ApprovedSchemaDiffers -> "approved-schema-changed"; NotApproved -> "not approved")
          if status == Approved
            then pure ()
            else
              TextIO.putStrLn
                ( "    { remoteName = \""
                    <> offered.name
                    <> "\", description = \"…\", inputSchema = "
                    <> Text.pack (show (Text.Encoding.decodeUtf8Lenient (LazyChar8.toStrict (Aeson.encode offered.inputSchema))))
                    <> ", operationClass = A.OperationClass.<Observation|IdempotentMutation|IrreversibleEmission> }"
                )
      )
      session.discovered
    session.close
  where
    repositorySelector named
      | "mori://" `Text.isPrefixOf` Text.pack named = SelectByIdentity (repositoryId (Text.pack named))
      | otherwise = SelectByPath named
    stateStore = do
      directory <- maybe defaultStateDirectory pure config.localOperatorStateDirectory
      openGrantStore directory >>= either (die . Text.pack . show) pure

renderRepository :: LocalRepository -> Text
renderRepository repository =
  "repository " <> repositoryIdText repository.identity <> " " <> Text.pack repository.source <> " base " <> repository.base <> ", " <> placementText repository.placement

renderApproval :: AgentApproval -> Text
renderApproval approval =
  Text.unlines
    ( ("approval " <> agentNameText approval.agent <> " on " <> repositoryIdText approval.repository <> ": " <> Text.intercalate ", " (capabilityIdText <$> Set.toList approval.capabilities))
        : (renderRule <$> approval.rules)
          <> [maybe "  budget default" renderBudget approval.budget]
    )
  where
    renderRule rule =
      "  rule "
        <> ruleNameText rule.name
        <> " "
        <> programPathText rule.program
        <> " "
        <> Text.unwords rule.arguments
        <> " (deadline "
        <> Text.pack (show (launchDeadlineSeconds rule.deadline))
        <> " s, output "
        <> Text.pack (show (outputLimitBytes rule.outputLimit))
        <> " bytes)"
    renderBudget Budget {modelAttempts, toolAttempts, tokens, minutes} =
      "  budget " <> Text.pack (show modelAttempts) <> " model attempts, " <> Text.pack (show toolAttempts) <> " tool attempts, " <> Text.pack (show tokens) <> " tokens, " <> Text.pack (show minutes) <> " minutes"

renderGrant :: LocalGrant -> Text
renderGrant grant =
  "grant "
    <> shortDigest grant.digest
    <> " "
    <> agentNameText grant.agent
    <> " on "
    <> repositoryIdText grant.repository
    <> ": "
    <> Text.intercalate ", " (capabilityIdText <$> Set.toList grant.capabilities)
    <> case grant.grantedBy of
      ConfirmedByOperator at -> " (confirmed " <> Text.pack (iso8601Show at) <> ")"
      FromApprovalsFile -> " (approvals file)"

die :: Text -> IO a
die detail = do
  hPutStrLn stderr ("shikigami-local: " <> Text.unpack detail)
  exitFailure
