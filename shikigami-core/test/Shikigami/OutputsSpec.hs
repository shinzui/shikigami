-- | The kernel output contract and the local adapters (EP-8 M2 of
-- MasterPlan 22).
module Shikigami.OutputsSpec (tests) where

import Data.Aeson (Value (..), object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.UUID qualified as UUID
import Data.Unique (hashUnique, newUnique)
import Keiro.Workflow (WorkflowId (..), WorkflowName (..))
import Keiro.Workflow.Awakeable (AwakeableId (..))
import Shikigami.Agent.Approval (ApprovalRequest (..), localInboxChannel, reviewRequestIdFor)
import Shikigami.Agent.Approval.LocalInbox
import Shikigami.Agent.Approval.Workflow (ApprovalNotifier (..))
import Shikigami.Agent.Decl (AgentDecl (..))
import Shikigami.Agent.Loader (loadAgent)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Duration (parseDuration)
import Shikigami.Output
import Shikigami.Output.Local
import System.Directory (getTemporaryDirectory, removePathForcibly)
import System.FilePath ((</>))
import System.Posix.Files (fileMode, getFileStatus, intersectFileModes)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "outputs"
    [ testCase "a declaration's own outputs win; none takes the composition default; no default keeps the journal" do
        let declared = OutputDecl {kind = localReportKind, config = object ["format" .= ("json" :: Text)]}
        Right withDefault <- pure (mkOutputRegistry [localReportAdapter "/tmp"] (DefaultOutput defaultLocalReport))
        resolveOutputs withDefault [declared] @?= DeclaredOutputs (declared :| [])
        resolveOutputs withDefault [] @?= CompositionDefault defaultLocalReport
        resolveOutputs emptyOutputRegistry [] @?= JournalOnly
        renderResolvedOutputs (resolveOutputs withDefault []) @?= "local.report (composition default)",
      testCase "an unregistered kind or a rejected configuration is refused, naming what is registered" do
        Right registry <- pure (mkOutputRegistry [localReportAdapter "/tmp"] NoDefaultOutput)
        Right kawa <- pure (mkOutputKind "kawa.digest")
        either (Left . fmap renderOutputLoadError) Right (validateOutputs registry [OutputDecl kawa (object [])])
          @?= Left ("output kind kawa.digest is not registered here (registered: local.report)" :| [])
        case validateOutputs registry [OutputDecl localReportKind (object ["format" .= ("pdf" :: Text)])] of
          Left (InvalidOutputConfig _ _ :| []) -> pure ()
          other -> assertFailure (show (either (Just . fmap renderOutputLoadError) (const Nothing) other))
        either (const True) (const False) (mkOutputRegistry [localReportAdapter "/a", localReportAdapter "/b"] NoDefaultOutput) @?= True,
      testCase "local.report writes one private file per run and ordinal, idempotently" $ withDirectory \root -> do
        let adapter = localReportAdapter root
            delivery = OutputDelivery {run = WorkflowId "run-1", agent = either (error . show) id (mkAgentName "note"), ordinal = 0, output = defaultLocalReport, result = object ["reply" .= ("Hello." :: Text)]}
        DeliverInline deliver <- pure adapter.route
        Right first' <- deliver delivery
        Right again <- deliver delivery
        first'.location @?= again.location
        first'.location @?= Text.pack (root </> "note" </> "run-1-0.md")
        content <- TextIO.readFile (Text.unpack first'.location)
        assertBool "the reply is in the report" ("Hello." `Text.isInfixOf` content)
        mode <- fileMode <$> getFileStatus (Text.unpack first'.location)
        intersectFileModes mode 0o077 @?= 0,
      testCase "a declaration with no outputs loads with none, and the helper's output decodes" do
        loaded <- loadAgent "../agents/proof/portable-note.dhall"
        decl <- either (assertFailure . show) pure loaded
        decl.outputs @?= [],
      testCase "the local inbox holds one private ask per review and nothing after removal" $ withDirectory \root -> do
        let inbox = localInboxDirectory root
            reviewId = reviewRequestIdFor (WorkflowName "shikigami.agent-run") (WorkflowId "run-1") 0 "output-local.report-0"
            Right deadline = parseDuration 900
            token = AwakeableId (maybe (error "uuid") id (UUID.fromText "11111111-2222-3333-4444-555555555555"))
        Right () <- (localInboxNotifier inbox).postAsk reviewId token deadline ApprovalRequest {prompt = "Deliver?", context = Null, channel = localInboxChannel}
        [pendingAsk] <- listPendingApprovals inbox
        pendingAsk.prompt @?= "Deliver?"
        pendingToken pendingAsk @?= Just token
        mode <- fileMode <$> getFileStatus (inbox </> Text.unpack pendingAsk.reviewId <> ".json")
        intersectFileModes mode 0o077 @?= 0
        removePendingApproval inbox pendingAsk.reviewId
        listPendingApprovals inbox >>= (@?= [])
    ]

withDirectory :: (FilePath -> IO a) -> IO a
withDirectory action = do
  temporary <- getTemporaryDirectory
  unique <- hashUnique <$> newUnique
  let directory = temporary </> ("shikigami-outputs-test-" <> show unique)
  removePathForcibly directory
  result <- action directory
  removePathForcibly directory
  pure result
