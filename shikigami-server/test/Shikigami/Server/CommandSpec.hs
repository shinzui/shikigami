-- | The @shikigami@ administrative command line still offers every command.
--
-- The commands in this package arrived here from a package that no longer
-- exists. A command that was dropped in that move, or wired to the wrong
-- implementation, would still compile — every subcommand parser has the same
-- type. Only running the parser catches it.
--
-- These tests drive @optparse-applicative@ purely with @execParserPure@ rather
-- than executing the built binary: no build-tool dependency, no process
-- spawning, and the rendered help text is available to assert on.
module Shikigami.Server.CommandSpec (tests) where

import Control.Lens ((&), (.~))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.Generics.Labels ()
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableIdText)
import Options.Applicative
import Settei.Env (envSnapshot, environmentSource)
import Shikigami.Agent.Approval (ApprovalDecision (..))
import Shikigami.App.Config (AppConfig (..), Role (..), environmentBindings, revealSecretText)
import Shikigami.App.Config.Load (ConfigOptions (..), ConfigRun (..), DiagnosticMode (..), appConfigRun)
import Shikigami.Execution.Resources qualified as Resources
import Shikigami.Server.Command (adminInfo, adminPrefs, adminSubcommands)
import Shikigami.Server.Command.Ops (redactDatabaseUrl)
import Shikigami.Server.Command.ResolveApproval (resolutionResult, resolveApprovalOptionsParser)
import Shikigami.Server.Command.Resources (resourceView)
import Shikigami.StateRevision (StateRevision, parseRevision)
import System.Exit (ExitCode (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "administrative command line"
    [ testCase "every administrative command is present" $
        fmap fst adminSubcommands
          @?= [ "validate",
                "render-lifecycle",
                "enqueue-run",
                "resolve-approval",
                "publish-fixture",
                "stub-kawa",
                "stub-kanmon",
                "danwa-spike",
                "grants",
                "agents",
                "runs",
                "resources",
                "executions",
                "workers"
              ],
      testCase "executions inspect accepts bounded history pagination" do
        case execParserPure adminPrefs adminInfo ["executions", "inspect", "execution-1", "--json", "--after", "20", "--limit", "5"] of
          Success (chosen, _) -> assertBool "execution action selected" (not (isNothing chosen))
          _ -> assertBool "executions did not parse" False,
      testCase "workers inspect accepts bounded assignment pagination" do
        case execParserPure adminPrefs adminInfo ["workers", "inspect", "session-1", "--json", "--after", "20", "--limit", "5"] of
          Success (chosen, _) -> assertBool "worker action selected" (not (isNothing chosen))
          _ -> assertBool "workers did not parse" False,
      testCase "worker sends require a stable operation key and expected ownership" do
        let args = ["workers", "send", "session-1", "--operation", "send-1", "--expected-revision", "3", "--epoch", "0", "--instruction-file", "instruction.json"]
        case execParserPure adminPrefs adminInfo args of
          Success (chosen, _) -> assertBool "worker send selected" (not (isNothing chosen))
          _ -> assertBool "worker send did not parse" False
        case execParserPure adminPrefs adminInfo ["workers", "send", "session-1", "--instruction-file", "instruction.json"] of
          Failure _ -> pure ()
          _ -> assertBool "missing operation and revision admitted" False,
      testCase "worker revision and ownership flags reject negative integers" do
        let args revision epoch = ["workers", "send", "session-1", "--operation", "send-1", "--expected-revision", revision, "--epoch", epoch, "--instruction-file", "instruction.json"]
        mapM_ (\values -> case execParserPure adminPrefs adminInfo values of Failure _ -> pure (); _ -> assertBool "negative domain counter admitted" False) [args "-1" "0", args "0" "-1"],
      testCase "worker commands cannot choose a replacement resource root" do
        case execParserPure adminPrefs adminInfo ["workers", "cancel", "session-1", "--operation", "cancel-1", "--expected-revision", "3", "--epoch", "0", "--root", "replacement"] of
          Failure _ -> pure ()
          _ -> assertBool "replacement root admitted" False,
      testCase "resources inspect accepts a root and JSON output" do
        case execParserPure adminPrefs adminInfo ["resources", "inspect", "root-1", "--json"] of
          Success (chosen, _) -> assertBool "resources action selected" (not (isNothing chosen))
          _ -> assertBool "resources did not parse" False,
      testCase "resource JSON distinguishes held unknown usage from measured consumption" do
        let now = UTCTime (fromGregorian 2026 10 27) 0
            envelope = Resources.Envelope (Map.singleton Resources.Tokens (Resources.Limited 100)) now
            usage = Resources.Usage (Map.singleton Resources.Tokens 3) (Map.singleton Resources.Tokens 10)
            root = Resources.Root envelope (fixtureRevision 0) False Nothing False 1 1 (Map.singleton Resources.Tokens 3) usage
            result = resourceView now root
        case result of
          Aeson.Object fields -> do
            KeyMap.lookup "unknownAttempts" fields @?= Just (Aeson.Number 1)
            KeyMap.lookup "measuredUsage" fields @?= Just (Aeson.toJSON root.known)
            KeyMap.lookup "heldIncludingAllocations" fields @?= Just (Aeson.toJSON usage.held)
            assertBool "one bounded payload-free summary" (Lazy.length (Aeson.encode result) < 4096)
          _ -> assertBool "resource summary must be an object" False,
      testCase "shikigami --help lists every command" do
        let rendered = helpTextOf ["--help"]
        assertBool ("no usage line:\n" <> rendered) ("Usage:" `isInfixOf` rendered)
        mapM_
          ( \(name, _) ->
              assertBool (name <> " missing from top-level help:\n" <> rendered) (name `isInfixOf` rendered)
          )
          adminSubcommands,
      testCase "shikigami reports its version offline" $
        case execParserPure adminPrefs adminInfo ["--version"] of
          Failure failure -> do
            let (message, exitCode) = renderFailure failure "shikigami"
            exitCode @?= ExitSuccess
            assertBool ("version does not name the executable: " <> message) ("shikigami" `isInfixOf` message)
          _ -> assertBool "--version did not exit through optparse-applicative" False,
      testCase "every command renders its own --help" $
        mapM_
          ( \(name, _) -> do
              let rendered = helpTextOf [name, "--help"]
              assertBool
                (name <> ": --help produced no usage line:\n" <> rendered)
                ("Usage:" `isInfixOf` rendered)
          )
          adminSubcommands,
      testCase "stub-kawa keeps its republish options" do
        let rendered = helpTextOf ["stub-kawa", "--help"]
        mapM_
          (\flag -> assertBool ("stub-kawa help does not mention " <> flag) (flag `isInfixOf` rendered))
          ["--port", "--republish-topic", "--broker"],
      testCase "stub-kanmon exposes only its port and repeatable destination allow-list" do
        let rendered = helpTextOf ["stub-kanmon", "--help"]
        mapM_
          (\flag -> assertBool ("stub-kanmon help does not mention " <> flag) (flag `isInfixOf` rendered))
          ["--port", "--allow-conversation"]
        assertBool ("stub-kanmon must not accept a token argument:\n" <> rendered) (not ("--token" `isInfixOf` rendered))
        case execParserPure adminPrefs adminInfo ["stub-kanmon", "--port", "8090", "--allow-conversation", "conv_1", "--allow-conversation", "conv_2"] of
          Success (chosen, _) -> assertBool "stub-kanmon did not select an action" (not (isNothing chosen))
          Failure failure ->
            let (message, _) = renderFailure failure "shikigami"
             in assertBool ("stub-kanmon options did not parse:\n" <> message) False
          CompletionInvoked _ -> assertBool "unexpected completion invocation" False,
      testCase "stub-kanmon rejects a token flag" $
        case execParserPure adminPrefs adminInfo ["stub-kanmon", "--port", "8090", "--token", "secret"] of
          Success _ -> assertBool "stub-kanmon accepted a plaintext token argument" False
          Failure _ -> pure ()
          CompletionInvoked _ -> assertBool "unexpected completion invocation" False,
      testCase "danwa-spike keeps its participant options" do
        let rendered = helpTextOf ["danwa-spike", "--help"]
        mapM_
          (\flag -> assertBool ("danwa-spike help does not mention " <> flag) (flag `isInfixOf` rendered))
          ["--danwa-url", "--human", "--agent"],
      testCase "resolve-approval accepts exactly one typed decision" do
        let token = "123e4567-e89b-42d3-a456-426614174000"
        case parseResolution [token, "--approve"] of
          Success (awakeableId, Approved _) -> awakeableIdText awakeableId @?= Text.pack token
          other -> assertBool ("approve form did not parse: " <> showParse other) False
        case parseResolution [token, "--reject", "not approved"] of
          Success (awakeableId, Rejected reason) -> do
            awakeableIdText awakeableId @?= Text.pack token
            reason @?= "not approved"
          other -> assertBool ("reject form did not parse: " <> showParse other) False
        mapM_
          ( \args -> case parseResolution args of
              Failure _ -> pure ()
              _ -> assertBool ("invalid resolve-approval form parsed: " <> show args) False
          )
          [ [token],
            [token, "--approve", "--reject", "no"],
            ["not-a-uuid", "--approve"]
          ],
      testCase "resolve-approval selects success and unknown-token exits" do
        let token = "123e4567-e89b-42d3-a456-426614174000"
        case parseResolution [token, "--approve"] of
          Success (awakeableId, _) -> do
            resolutionResult awakeableId True @?= ("approval " <> Text.pack token <> " resolved: true", ExitSuccess)
            resolutionResult awakeableId False
              @?= ("approval " <> Text.pack token <> " resolved: false (unknown or already resolved)", ExitFailure 1)
          _ -> assertBool "fixture token did not parse" False,
      -- The diagnostics live at the top level rather than inside a subcommand,
      -- because `shikigami --describe-config` must answer without being told
      -- which command it is about to not run.
      testCase "the top-level command line offers every configuration diagnostic" do
        let rendered = helpTextOf ["--help"]
        mapM_
          (\flag -> assertBool ("top-level help does not mention " <> flag <> ":\n" <> rendered) (flag `isInfixOf` rendered))
          [ "--config",
            "--set",
            "--describe-config",
            "--describe-config-json",
            "--explain-config",
            "--explain-config-json",
            "--check-config"
          ],
      -- A diagnostic with no subcommand has to parse: it is how an operator
      -- inspects the schema, and there is nothing to run.
      testCase "a diagnostic parses with no subcommand at all" $
        case execParserPure adminPrefs adminInfo ["--describe-config"] of
          Success (chosen, _) -> assertBool "no subcommand should have been chosen" (isNothing chosen)
          Failure failure ->
            let (message, _) = renderFailure failure "shikigami"
             in assertBool ("--describe-config alone did not parse:\n" <> message) False
          CompletionInvoked _ -> assertBool "unexpected completion invocation" False,
      -- `agents list` is the one verb that answers with no database, which is
      -- what makes it usable when the database is the thing that is broken.
      testCase "agents list offers --json and takes no target argument" do
        let rendered = helpTextOf ["agents", "list", "--help"]
        assertBool ("agents list help does not mention --json:\n" <> rendered) ("--json" `isInfixOf` rendered),
      testCase "agents exposes list and sync, and sync offers JSON and explicit aliases" do
        let groupHelp = helpTextOf ["agents", "--help"]
            syncHelp = helpTextOf ["agents", "sync", "--help"]
        mapM_
          (\verb -> assertBool ("agents help does not mention " <> verb <> ":\n" <> groupHelp) (verb `isInfixOf` groupHelp))
          ["list", "sync"]
        assertBool ("agents sync help does not mention --json:\n" <> syncHelp) ("--json" `isInfixOf` syncHelp)
        assertBool ("agents sync help does not mention --alias:\n" <> syncHelp) ("--alias" `isInfixOf` syncHelp),
      testCase "a subcommand's downstream flags name the configuration keys they set" do
        assertMentions ["publish-fixture", "--help"] ["kafka.broker", "kafka.activity.topic"]
        assertMentions ["stub-kawa", "--help"] ["kafka.broker"]
        assertMentions ["danwa-spike", "--help"] ["sinks.danwa.base_url"],
      -- The mounted keiro-ops tree is not in `adminSubcommands` -- it cannot be,
      -- because keiro-ops exports its tree as one ParserInfo over an abstract
      -- type -- so nothing above covers it. A mount that silently stopped
      -- resolving would still compile and would still pass every test before
      -- this one.
      testCase "every mounted keiro-ops group is reachable from the top level" do
        let rendered = helpTextOf ["--help"]
        mapM_
          (\name -> assertBool (name <> " is not mounted:\n" <> rendered) (name `isInfixOf` rendered))
          ["wf", "timer", "outbox", "inbox", "pgmq", "projection", "shard", "snapshot", "stream", "replay-audit", "rebuild"],
      testCase "a mounted group renders its own help" do
        let rendered = helpTextOf ["wf", "--help"]
        mapM_
          (\verb -> assertBool ("wf help does not mention " <> verb <> ":\n" <> rendered) (verb `isInfixOf` rendered))
          ["list", "show", "cancel", "resurrect", "lease"],
      testCase "native database option participates in Settei precedence and redacted diagnostics" do
        let target = "postgresql://operator:SECRET_CLI_PASSWORD@localhost/cli-target"
            environment = environmentSource environmentBindings (envSnapshot [("PG_CONNECTION_STRING", "postgresql:///shell-target")])
        case execParserPure adminPrefs adminInfo ["--database-url", target, "aggregate", "types"] of
          Success (Just (_, sources), options) -> do
            let configured = (options & #namedSources .~ (options.namedSources <> sources))
                run = appConfigRun AdminRole configured (Right []) environment
            run.exitCode @?= 0
            case run.resolved of
              Just config -> fmap revealSecretText config.databaseUrl @?= Just (Text.pack target)
              Nothing -> assertBool "native database option was not resolved" False
            let diagnostic = appConfigRun AdminRole (configured {diagnosticMode = ExplainJson}) (Right []) environment
            diagnostic.exitCode @?= 0
            assertBool "named flag appears in provenance" ("--database-url" `Text.isInfixOf` diagnostic.standardOutput)
            assertBool "secret flag value is redacted" (not ("SECRET_CLI_PASSWORD" `Text.isInfixOf` diagnostic.standardOutput))
          _ -> assertBool "native database option did not parse" False,
      -- keiro-ops declares --force before its subcommand, but the message it
      -- prints tells the operator to re-run `... wf cancel NAME ID --force`
      -- with the flag last. This pins that the printed form actually parses, so
      -- a preview can never advertise a command this binary would reject. It
      -- passes under either parser preference -- an unrecognised option is
      -- handed back to the parent parser, and --force belongs to the parent --
      -- so it guards the arrangement, not the preference.
      testCase "a mutating verb accepts --force after its arguments" $
        case execParserPure adminPrefs adminInfo ["wf", "cancel", "shikigami.agent-run", "run-1", "--force"] of
          Success (chosen, _) ->
            assertBool "no command was chosen for a forced cancel" (not (isNothing chosen))
          Failure failure ->
            let (message, _) = renderFailure failure "shikigami"
             in assertBool ("a forced cancel did not parse:\n" <> message) False
          CompletionInvoked _ -> assertBool "unexpected completion invocation" False,
      -- The companion to the case above: a flag nobody declares must still be
      -- refused there. Without this, the case above would pass just as happily
      -- against a parser that swallowed anything after the arguments.
      testCase "an undeclared flag in that same position is refused" $
        case execParserPure adminPrefs adminInfo ["wf", "cancel", "shikigami.agent-run", "run-1", "--nonsense"] of
          Success _ -> assertBool "an undeclared flag was accepted after a verb's arguments" False
          Failure _ -> pure ()
          CompletionInvoked _ -> assertBool "unexpected completion invocation" False,
      -- The audit line is built from the process arguments, which is the one
      -- place a connection string arrives in the clear.
      testCase "no spelling of --database-url survives into an audit line" do
        let secret = "postgresql://user:hunter2@host/db"
        mapM_
          ( \argv ->
              assertBool
                ("a connection string survived redaction: " <> show (redactDatabaseUrl argv))
                (not (secret `Text.isInfixOf` redactDatabaseUrl argv))
          )
          [ ["wf", "list", "--database-url", secret],
            ["wf", "list", "--database-url=" <> secret],
            ["--database-url", secret, "wf", "list"]
          ]
        -- Redaction must not eat the command itself.
        assertBool
          "redaction dropped the verb"
          ("wf list" `Text.isInfixOf` redactDatabaseUrl ["wf", "list", "--database-url", secret])
    ]

assertMentions :: [String] -> [String] -> IO ()
assertMentions args expected =
  mapM_
    (\needle -> assertBool (unwords args <> " does not mention " <> needle <> ":\n" <> rendered) (needle `isInfixOf` rendered))
    expected
  where
    rendered = helpTextOf args

-- | Run the administrative parser on the given arguments and return what it
-- printed.
--
-- @--help@ always ends in a parser 'Failure'; the help text is that failure's
-- rendering. A 'Success' would mean the parser ran a command instead of showing
-- help, which is itself the bug these tests look for.
helpTextOf :: [String] -> String
helpTextOf args =
  case execParserPure adminPrefs adminInfo args of
    Failure failure -> let (message, _) = renderFailure failure "shikigami" in message
    Success _ -> "unexpected success: the parser did not handle --help"
    CompletionInvoked _ -> "unexpected completion invocation"

parseResolution :: [String] -> ParserResult (AwakeableId, ApprovalDecision)
parseResolution = execParserPure defaultPrefs (info (resolveApprovalOptionsParser <**> helper) mempty)

showParse :: ParserResult a -> String
showParse = \case
  Success _ -> "success with unexpected decision"
  Failure failure -> fst (renderFailure failure "resolve-approval")
  CompletionInvoked _ -> "completion invoked"

fixtureRevision :: Integer -> StateRevision scope
fixtureRevision value = either (error . show) id (parseRevision value)
