-- | Declared CLI tools (EP-3 of MasterPlan 22): the pure pattern and ceiling
-- rules, the declaration's codecs, and the host runner driven with ordinary
-- executables.
module Shikigami.DeclaredToolsSpec (tests) where

import Data.Aeson (Value (..), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text.Encoding qualified as Text.Encoding
import Shikigami.Agent.Decl (AgentDecl (..), requestedOverlays)
import Shikigami.Agent.DeclarationValue (declarationCoordinate)
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Capability.Catalog (ExecutionMode (Durable))
import Shikigami.Capability.Declared
import Shikigami.Capability.Declared.Catalog
import Shikigami.Capability.Declared.Local
import Shikigami.Capability.Mcp
import Shikigami.Capability.Mcp.Local (mcpBindingRevision)
import Shikigami.Capability.Overlay (CapabilityDescriptor (..), CapabilityOperationClass (..), capabilityIdText)
import Shikigami.Capability.Provider (CapabilityRun (..), CapabilityScope (..))
import Shikigami.Record (memoryRecord, unspecifiedTier)
import Shikigami.Trust.LocalOperator.Approvals (resolveProgram)
import Shikigami.Workspace.Local.Launcher (hostProcessLauncher)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "declared tools"
    [ testCase "a pattern admits its prefix and the trailing words it allows" do
        matchesPattern (pat ["registry", "show"] AnyTrailing) ["registry", "show", "shinzui/keiro"] @?= True
        matchesPattern (pat ["docket", "status"] NoTrailing) ["docket", "status"] @?= True
        matchesPattern (pat ["docket", "status"] NoTrailing) ["docket", "status", "--all"] @?= False
        matchesPattern (pat ["path"] (AtMostTrailing 1)) ["path", "a", "b"] @?= False
        matchesPattern (pat ["registry", "show"] AnyTrailing) ["registry", "list"] @?= False,
      testCase "a narrower pattern lies within a wider one, never the reverse" do
        patternWithin (pat ["registry", "show"] AnyTrailing) (pat ["registry"] AnyTrailing) @?= True
        patternWithin (pat ["registry"] AnyTrailing) (pat ["registry", "show"] AnyTrailing) @?= False
        patternWithin (pat ["path", "x"] NoTrailing) (pat ["path"] (AtMostTrailing 1)) @?= True
        patternWithin (pat ["path"] AnyTrailing) (pat ["path"] (AtMostTrailing 3)) @?= False,
      testCase "an argument vector outside every declared pattern is refused" do
        decideCliArguments mori ["registry", "show", "shinzui/keiro"] @?= Right ()
        either (Left . renderCliRefusal) Right (decideCliArguments mori ["registry", "list"]) @?= Left "arguments outside declared patterns for mori",
      testCase "the operator ceiling bounds a tool of its name and leaves the others alone" do
        checkDeclaredTools emptyToolCatalog [mori, mina] @?= Right ()
        checkDeclaredTools (catalogWith (ceiling' ["path"] Observation)) [mori, mina] @?= Left (PatternOutsideCeiling (name' "mori") (pat ["registry", "show"] AnyTrailing))
        checkDeclaredTools (catalogWith (bound (OnPath (exe "mori")) [pat ["registry"] AnyTrailing, pat ["path"] AnyTrailing] Observation)) [mori] @?= Right ()
        checkDeclaredTools (catalogWith (bound (OnPath (exe "other")) [pat ["registry"] AnyTrailing, pat ["path"] AnyTrailing] Observation)) [mori] @?= Left (ExecutableDiffersFromCeiling (name' "mori"))
        checkDeclaredTools (catalogWith (ceiling' ["registry"] Observation)) [tool "mori" (OnPath (exe "mori")) (pat ["registry", "show"] AnyTrailing :| []) IdempotentMutation Nothing] @?= Left (OperationClassAboveCeiling (name' "mori") IdempotentMutation Observation)
        checkDeclaredTools emptyToolCatalog [mori, mori] @?= Left (DuplicateToolDeclaration (name' "mori")),
      testCase "checked words refuse what a declaration may not say" do
        either (const True) (const False) (mkToolName "Mori") @?= True
        either (const True) (const False) (mkExecutableName "bin/mori") @?= True
        either (const True) (const False) (mkArgumentWord "a\nb") @?= True
        either (const True) (const False) (mkCallTimeout 601) @?= True,
      testCase "repo-inventory decodes, requests cli.mori and cli.mina, and keeps its tools in the journal" do
        loaded <- loadAgent "../agents/repo-inventory.dhall"
        decl <- either (assertFailure . show) pure loaded
        (.name) <$> cliTools decl.tools @?= [name' "mori", name' "mina"]
        capabilityIdText <$> requestedOverlays decl @?= ["cli.mori", "cli.mina", "mcp.git"]
        (mcpServerIdText . (.server)) <$> mcpRequests decl.tools @?= ["git"]
        Aeson.decode (Aeson.encode decl) @?= Just decl,
      testCase "a declaration without tools keeps its journal bytes" do
        loaded <- loadAgent "../agents/local-maintainer.dhall"
        decl <- either (assertFailure . show) pure loaded
        case Aeson.toJSON decl of
          Object fields -> KeyMap.member "tools" fields @?= False
          _ -> assertFailure "not an object",
      testCase "the revision changes with a pattern and the located executable" do
        Just echo <- resolveProgram "/bin/echo"
        Just cat <- resolveProgram "/bin/cat"
        let revision tool program = (cliToolDescriptor tool program).revision
        assertBool "pattern" (revision mori echo /= revision (tool "mori" (OnPath (exe "mori")) (pat ["path"] AnyTrailing :| []) Observation Nothing) echo)
        assertBool "executable" (revision mori echo /= revision mori cat)
        revision mori echo @?= revision mori echo,
      testCase "the runner runs an admitted call with no shell and records both decisions" do
        (record, events) <- memoryRecord
        let echoTool = tool "mori" (atPath "/bin/echo") (pat ["registry", "show"] AnyTrailing :| []) Observation Nothing
        Right [located] <- locateCliTools [echoTool]
        let host = CliToolHost {record, tier = unspecifiedTier, agent = agentName, root = "/tmp", launcher = hostProcessLauncher, host = "skill"}
        admitted <- runCliTool host scope located ["registry", "show", "$HOME;", "x"]
        refused <- runCliTool host scope located ["registry", "list"]
        case admitted of
          Right (Object fields) -> KeyMap.lookup "stdout" fields @?= Just (String "registry show $HOME; x\n")
          other -> assertFailure (show other)
        refused @?= Left "arguments outside declared patterns for mori"
        recorded <- events
        length recorded @?= 2,
      testCase "the runner ends a call at its deadline and bounds its output" do
        (record, _) <- memoryRecord
        let host = CliToolHost {record, tier = unspecifiedTier, agent = agentName, root = "/tmp", launcher = hostProcessLauncher, host = "skill"}
            limited = CallLimits {timeoutSeconds = either (error . show) id (mkCallTimeout 1), outputBytes = either (error . show) id (mkCallOutputLimit 1024)}
        Right [sleeper] <- locateCliTools [tool "sleep" (atPath "/bin/sleep") (pat [] AnyTrailing :| []) Observation (Just limited)]
        Right [yes] <- locateCliTools [tool "yes" (atPath "/usr/bin/yes") (pat [] AnyTrailing :| []) Observation (Just limited)]
        slept <- runCliTool host scope sleeper ["30"]
        case slept of
          Right (Object fields) -> KeyMap.lookup "timedOut" fields @?= Just (Bool True)
          other -> assertFailure (show other)
        flooded <- runCliTool host scope yes []
        case flooded of
          Right (Object fields) -> KeyMap.lookup "truncated" fields @?= Just (Bool True)
          other -> assertFailure (show other),
      testCase "discovered MCP tools must match the approved ones; extra tools are ignored" do
        let requested = mcpName "git_status" :| [mcpName "git_log"]
            offered = [DiscoveredMcpTool "git_status" statusSchema, DiscoveredMcpTool "git_log" logSchema, DiscoveredMcpTool "git_commit" statusSchema]
        verifyDiscoveredTools gitBinding requested offered @?= Right ()
        verifyDiscoveredTools gitBinding requested (take 1 offered) @?= Left (ApprovedToolMissing (mcpName "git_log"))
        verifyDiscoveredTools gitBinding requested [DiscoveredMcpTool "git_status" logSchema, DiscoveredMcpTool "git_log" logSchema] @?= Left (ApprovedSchemaChanged (mcpName "git_status"))
        verifyDiscoveredTools gitBinding (mcpName "git_commit" :| []) offered @?= Left (RequestedToolNotApproved (mcpName "git_commit"))
        discoveryStatus gitBinding (DiscoveredMcpTool "git_commit" statusSchema) @?= NotApproved,
      testCase "an MCP request needs its server bound and its tools approved" do
        let catalog = ToolCatalog {cli = [], mcp = [gitBinding]}
            request tools = McpToolRequest {server = mcpServer "git", tools}
        fmap (fmap snd) (checkMcpRequests catalog [request (mcpName "git_status" :| [])]) @?= Right [request (mcpName "git_status" :| [])]
        fmap (const ()) (checkMcpRequests catalog [request (mcpName "git_commit" :| [])]) @?= Left (McpToolNotApproved (mcpServer "git") (mcpName "git_commit"))
        fmap (const ()) (checkMcpRequests emptyToolCatalog [request (mcpName "git_status" :| [])]) @?= Left (UncataloguedMcpServer (mcpServer "git")),
      testCase "the binding's revision changes with an approved schema" do
        let changed = McpBinding {server = mcpServer "git", command = "/bin/false", arguments = [LiteralArgument "--repository", WorkspaceRootArgument], environment = [], tools = [approved "git_status" logSchema, approved "git_log" logSchema]}
        assertBool "schema" (mcpBindingRevision gitBinding /= mcpBindingRevision changed)
        mcpBindingRevision gitBinding @?= mcpBindingRevision gitBinding
    ]
  where
    scope = CapabilityScope {runId = OneOffRun "declared-tools-test", principal = declarationCoordinate "principal_test", mode = Durable}
    agentName = either (error . show) id (mkAgentName "repo-inventory")

atPath :: Text -> ExecutableRef
atPath = either (error . show) id . mkAtPath

pat :: [Text] -> Trailing -> ArgumentPattern
pat prefix trailing = ArgumentPattern {prefix = word <$> prefix, trailing}
  where
    word = either (error . show) id . mkArgumentWord

name' :: Text -> ToolName
name' = either (error . show) id . mkToolName

exe :: Text -> ExecutableName
exe = either (error . show) id . mkExecutableName

tool :: Text -> ExecutableRef -> NonEmpty ArgumentPattern -> CapabilityOperationClass -> Maybe CallLimits -> CliToolDecl
tool named executable allow operationClass limits = CliToolDecl {name = name' named, executable, allow, workingDirectory = WorkspaceRoot, operationClass, limits}

mori :: CliToolDecl
mori = tool "mori" (OnPath (exe "mori")) (pat ["registry", "show"] AnyTrailing :| [pat ["path"] AnyTrailing]) Observation Nothing

mina :: CliToolDecl
mina = tool "mina" (OnPath (exe "mina")) (pat ["docket", "status"] NoTrailing :| []) Observation Nothing

bound :: ExecutableRef -> [ArgumentPattern] -> CapabilityOperationClass -> CliToolCeiling
bound executable allow maximumOperationClass = CliToolCeiling {name = name' "mori", executable, allow, maximumOperationClass}

ceiling' :: [Text] -> CapabilityOperationClass -> CliToolCeiling
ceiling' prefix = bound (OnPath (exe "mori")) [pat prefix AnyTrailing]

catalogWith :: CliToolCeiling -> ToolCatalog
catalogWith limit = ToolCatalog {cli = [limit], mcp = []}

mcpName :: Text -> McpToolName
mcpName = either (error . show) id . mkMcpToolName

mcpServer :: Text -> McpServerId
mcpServer = either (error . show) id . mkMcpServerId

statusSchema :: Value
statusSchema = Aeson.object ["type" .= ("object" :: Text), "title" .= ("statusArguments" :: Text)]

logSchema :: Value
logSchema = Aeson.object ["type" .= ("object" :: Text), "title" .= ("logArguments" :: Text)]

approved :: Text -> Value -> ApprovedMcpTool
approved remote schema = ApprovedMcpTool {remoteName = mcpName remote, description = remote, inputSchema = Text.Encoding.decodeUtf8 (LazyByteString.toStrict (Aeson.encode schema)), operationClass = Observation}

gitBinding :: McpBinding
gitBinding = McpBinding {server = mcpServer "git", command = "/bin/false", arguments = [LiteralArgument "--repository", WorkspaceRootArgument], environment = [], tools = [approved "git_status" statusSchema, approved "git_log" logSchema]}
