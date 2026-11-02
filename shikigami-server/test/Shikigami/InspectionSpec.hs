{-# LANGUAGE GADTs #-}

module Shikigami.InspectionSpec (tests) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as Lazy
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Keiro.Command (defaultRunCommandOptions, runCommand)
import Keiro.EventStream (EventStream (..))
import Keiro.EventStream.Validate (unvalidated)
import Keiro.Inspection.Aggregate qualified as Aggregate
import Keiro.Inspection.Cursor (InspectionCursor (..))
import Keiro.Ops.Aggregate qualified as OpsAggregate
import Keiro.Ops.Env (OpsEnv (..), OutputMode (..))
import Keiro.Ops.Render (OpsOutcome (..))
import Keiro.ReplayAudit (AuditTarget (..), SomeAuditTarget (..))
import Keiro.Stream qualified as Stream
import Kiroku.Store.Append (appendToStream)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Types (EventData (..), EventType (..), ExpectedVersion (..), StreamName (..))
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Transcript (ExecutionId (..), executionIdentity)
import Shikigami.ExecutionLifecycle.Generated.Domain qualified as Execution
import Shikigami.ExecutionLifecycle.Generated.EventStream (executionLifecycleCategory, executionLifecycleEventStream)
import Shikigami.Inspection.Aggregates (aggregateCatalog)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.RunEvidence.Catalog qualified as Evidence
import System.Directory (findExecutable)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, assertFailure, testCase)

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "inspection"
    [ testCase "display catalog covers every generated aggregate and has explicit safe keys" do
        let descriptors = Aggregate.listAggregateTypes aggregateCatalog
        assertEqual "generated audit census" (sort [target.category | SomeAuditTarget target <- Evidence.auditTargets]) (sort (map (.category) descriptors))
        mapM_ (\descriptor -> assertBool "no snapshot codec is claimed" (not descriptor.snapshotsConfigured && descriptor.snapshotPolicy == "never")) descriptors
        mapM_
          ( \(name, Aggregate.SomeAggregateInspector inspector) -> do
              let definition = unvalidated inspector.eventStream
                  expected = case name of
                    "ExecutionLifecycle" -> ["executionId", "pendingReceipts", "revision"]
                    "WorkerSessionLifecycle" -> ["revision", "sessionId"]
                    "ObjectiveLifecycle" -> ["objectiveId", "revision"]
                    "ObjectiveTurnAdmission" -> ["admissionKey"]
                    "RunEvidence" -> ["runEvidenceId", "runId"]
                    _ -> []
              case inspector.displayState definition.initialState definition.initialRegisters of
                Object fields -> assertEqual "display key allowlist" expected (sort (KeyMap.keys fields))
                _ -> assertFailure "display must be an explicit object"
          )
          (Map.toList aggregateCatalog),
      testCase "native CLI lists and displays one execution without its protected digest" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          tracer <- noopTracer
          let env = AppEnv (defaultConnectionSettings connection) tracer Nothing (Just store)
              identifier = "inspection-execution"
              command = Execution.AdmitExecution (Execution.AdmitExecutionData (executionIdentity identifier) "PRIVATE_SNAPSHOT_DIGEST")
          recorded <- runAppIO env (runCommand defaultRunCommandOptions executionLifecycleEventStream (Stream.entityStream executionLifecycleCategory identifier) command)
          case recorded of
            Right (Right _) -> pure ()
            _ -> assertFailure "failed to append native execution fixture"
          second <- runAppIO env (runCommand defaultRunCommandOptions executionLifecycleEventStream (Stream.entityStream executionLifecycleCategory "inspection-execution-2") (Execution.AdmitExecution (Execution.AdmitExecutionData (executionIdentity "inspection-execution-2") "PRIVATE_SECOND_DIGEST")))
          case second of
            Right (Right _) -> pure ()
            _ -> assertFailure "failed to append second native fixture"
          types <- cli connection ["aggregate", "types"]
          assertBool "actual execution descriptor is mounted" ("ExecutionLifecycle" `Text.isInfixOf` Text.decodeUtf8 (Lazy.toStrict . Aeson.encode $ types))
          page <- cli connection ["aggregate", "list", "--name", "ExecutionLifecycle", "--limit", "1"]
          assertBool "actual instance appears in the bounded page" (identifier `Text.isInfixOf` Text.decodeUtf8 (Lazy.toStrict . Aeson.encode $ page))
          case field "next_cursor" page of
            Just (String cursor) -> do
              next <- cli connection ["aggregate", "list", "--name", "ExecutionLifecycle", "--limit", "1", "--after", Text.unpack cursor]
              assertBool "exclusive next page" ("inspection-execution-2" `Text.isInfixOf` Text.decodeUtf8 (Lazy.toStrict (Aeson.encode next)))
              wrong <- OpsAggregate.runCommand (OpsEnv store Json False [] False) aggregateCatalog (OpsAggregate.List (OpsAggregate.ListOptions "WorkerSessionLifecycle" 1 (Just (InspectionCursor cursor))))
              case wrong of
                InspectionFailed "invalid_cursor" _ -> pure ()
                _ -> assertFailure "cursor was reinterpreted for another aggregate"
            _ -> assertFailure "first bounded page must supply a continuation"
          viewed <- cli connection ["aggregate", "show", "--name", "ExecutionLifecycle", "--id", Text.unpack identifier]
          case viewed of
            Object fields -> assertEqual "only allowlisted lifecycle fields" (Just (object ["executionId" .= identifier, "revision" .= (0 :: Int), "pendingReceipts" .= (0 :: Int)])) (KeyMap.lookup "state" fields)
            _ -> assertFailure "aggregate show returned no object"
          assertBool "protected digest never appears" (not ("PRIVATE_SNAPSHOT_DIGEST" `Text.isInfixOf` Text.decodeUtf8 (Lazy.toStrict . Aeson.encode $ viewed)))
          assertEqual "full replay is honest without a snapshot codec" (Just (object ["source" .= ("full_replay" :: Text), "reason" .= ("no_state_codec" :: Text)])) (field "hydration" viewed)
          snapshot <- cli connection ["aggregate", "snapshot", "--name", "ExecutionLifecycle", "--id", Text.unpack identifier]
          assertEqual "snapshot is absent" (Just (String "absent")) (field "status" snapshot)
          assertEqual "snapshot codec is not configured" (Just Null) (field "configured" snapshot)
          mapM_
            (\arguments -> cli connection arguments >> pure ())
            [["wf", "inspect", "list", "--limit", "1"], ["timer", "pending", "list", "--limit", "1"], ["projection", "status", "--limit", "1"], ["shard", "list"]],
      testCase "aggregate paging rejects a cursor from another catalog and invalid limits as typed failures" $
        withShikigamiFreshDatabase fixture \connection -> withStore (defaultConnectionSettings connection) \store -> do
          let env = OpsEnv store Json False [] False
          result <- OpsAggregate.runCommand env aggregateCatalog (OpsAggregate.List (OpsAggregate.ListOptions "ExecutionLifecycle" 501 Nothing))
          case result of
            InspectionFailed "invalid_page_size" _ -> pure ()
            _ -> assertFailure "invalid limit lost its typed inspection status"
          wrong <- OpsAggregate.runCommand env aggregateCatalog (OpsAggregate.List (OpsAggregate.ListOptions "ExecutionLifecycle" 1 (Just (InspectionCursor "not-a-cursor"))))
          case wrong of
            InspectionFailed "invalid_cursor" _ -> pure ()
            _ -> assertFailure "bad cursor lost its typed inspection status"
          tracer <- noopTracer
          let app = AppEnv (defaultConnectionSettings connection) tracer Nothing (Just store)
          appended <- runAppIO app (appendToStream (StreamName "executionLifecycle-corrupt") NoStream [EventData Nothing (EventType "unknown") (object []) Nothing Nothing Nothing])
          case appended of
            Left _ -> assertFailure "could not append corrupt fixture"
            Right _ -> pure ()
          case Map.lookup "ExecutionLifecycle" aggregateCatalog of
            Nothing -> assertFailure "missing execution inspector"
            Just (Aggregate.SomeAggregateInspector inspector) -> do
              corrupt <- runAppIO app (Aggregate.inspectAggregate inspector "corrupt")
              case corrupt of
                Right (Left (Aggregate.AggregateHydrationFailed _ _)) -> pure ()
                _ -> assertFailure "corrupt history was rendered as successful or empty state"
              missing <- runAppIO app (Aggregate.inspectAggregate inspector "missing")
              case missing of
                Right (Left (Aggregate.AggregateNotFound _)) -> pure ()
                _ -> assertFailure "missing aggregate was rendered as an initial lifecycle"
    ]

field :: Aeson.Key -> Value -> Maybe Value
field key (Object fields) = KeyMap.lookup key fields
field _ _ = Nothing

cli :: Text -> [String] -> IO Value
cli connection command = do
  binary <- findExecutable "shikigami" >>= maybe (assertFailure "Cabal must supply the built administrative executable" >> fail "missing build tool") pure
  (status, output, errors) <- readProcessWithExitCode binary (["--database-url", Text.unpack connection, "--json"] <> command) ""
  assertEqual "native CLI exit" ExitSuccess status
  assertBool "connection string is redacted from audit output" (not (connection `Text.isInfixOf` Text.pack errors))
  case Aeson.eitherDecodeStrict' (Text.encodeUtf8 (Text.pack output)) of
    Left failure -> assertFailure ("invalid inspection JSON: " <> failure) >> fail "invalid JSON"
    Right value -> pure value
