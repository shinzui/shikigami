{-# LANGUAGE DataKinds #-}

module Shikigami.ObjectiveTrackerWorkerSpec (tests) where

import Data.Generics.Labels ()
import Data.IORef
import Effectful (Eff)
import Keiro.Integration.Event qualified as Event
import Keiro.Outbox (PublishOutcome (..), defaultPublishOptions, listOutbox, publishClaimedOutbox)
import Keiro.Outbox.Types (OutboxRow (..))
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Connection qualified as Connection
import Shikigami.Action.Authorization (allowAllActionAuthorizerForTests)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.App (AppEffects, AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Identity (OperationId, parseOperationId)
import Shikigami.Flow.SinkOutbox.Publisher (publishTrackerRow, reconcilePublishedRow)
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Objective.Capability qualified as O
import Shikigami.Objective.Command qualified as OC
import Shikigami.Objective.Tracker.Command qualified as C
import Shikigami.Objective.Tracker.Config
import Shikigami.Objective.Tracker.Mapping (supportedMappingRevision)
import Shikigami.Objective.Tracker.Provider qualified as P
import Shikigami.Objective.Tracker.Store qualified as S
import Shikigami.Objective.Tracker.Types
import Shikigami.Objective.Types qualified as OT
import Shikigami.Prelude
import Shikigami.RunEvidence.Catalog qualified as Catalog
import Shikigami.Sink.Coordinate (parseSinkSession, zeroSinkOrdinal)
import Shikigami.Sink.Delivery qualified as Delivery
import Shikigami.Sink.Permission (parseSinkKind)
import Shikigami.StateRevision
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ObjectiveTrackerWorker"
    [ testCase "mixed callbacks retain delivered sink, delivered tracker and quarantined tracker independently" $
        withShikigamiFreshDatabase fixture \connectionString -> withStore (defaultConnectionSettings connectionString) \store -> do
          tracer <- noopTracer
          let env = AppEnv (defaultConnectionSettings connectionString) tracer Nothing (Just store)
              run :: Eff AppEffects a -> IO a
              run action = runAppIO env action >>= right
          _ <- run Catalog.registerProjectionCatalog
          let actor = OT.VerifiedCaller (checked (OT.parseCallerId "owner"))
              objectiveHost = O.ObjectiveHost (OT.defaultObjectiveSettings & #enabled .~ OT.ObjectivesEnabled) (pure (Right actor)) allowAllActionAuthorizerForTests (\_ _ -> pure (Right ())) (\_ _ -> pure (Right ())) (\_ -> pure (Left OT.ObjectiveInvalidEvidence))
              connection = Connection (key "connection") (key "incarnation") (key "weak-v1") "https://example.test" (key "account") Nothing [actor] [actor]
              settings = TrackerSettings TrackersEnabled [connection] 60 20 []
              provider scope =
                pure
                  ( Right
                      P.Provider
                        { capabilities = Capabilities scope.providerRevision OrderedObservations UnconditionalWrites NoIdempotency LookupApplied,
                          readResource = \_ -> pure (P.Observed (observation scope)),
                          publish = \_ _ -> pure (if scope.resourceId == key "delivered" then P.Acknowledged (key "remote-action") else P.OutcomeUnknown),
                          reconcile = \_ _ -> pure P.StillUnknown,
                          verifyReceipt = \_ _ _ -> pure Nothing
                        }
                  )
              host = S.TrackerHost objectiveHost settings provider
              request = OT.CreateRequest (checked (OT.parseTitle "routing")) (checked (OT.parseGoal "independent receipts")) (instructions "local") [OT.Criterion (checked (OT.parseCriterionKey "review")) (checked (OT.parseCriterionDescription "review")) OT.HumanVerifiable OT.JourneyOptional] []
          objective <- right =<< run (O.createObjective objectiveHost (operation "create") Nothing request)
          forM_ ["delivered", "unknown"] \name -> do
            let scope = ResourceScope connection.connectionId connection.incarnation (key name) connection.provider
            _ <- right =<< run (S.execute host objective.objectiveId (operation name) (C.Bind (key name) scope (FieldPolicy supportedMappingRevision IgnoreField IgnoreField ProgressSummaries)))
            pure ()
          _ <- right =<< run (O.executeCommand objectiveHost objective.objectiveId initialRevision (operation "progress") (OC.SetBlocked OT.IsBlocked))
          legacyCalls <- newIORef (0 :: Int)
          legacyReconciliations <- newIORef (0 :: Int)
          now <- getCurrentTime
          let message = Delivery.sinkMessageId "legacy-delivered"
              receipt = Delivery.DeliveryReceipt (Delivery.deliveryReceiptKey "legacy-delivered") message (checked (parseSinkSession "kioku_session_01kvxa7d2cezhs874g3n8dfgme")) (checked (mkAgentName "fixture")) zeroSinkOrdinal (fromMaybe (error "missing kawa kind") (parseSinkKind "KawaDigest")) Delivery.Delivered Nothing now
              legacy _ = do
                liftIO (modifyIORef' legacyCalls (+ 1))
                liftIO (Delivery.recordDelivery (Connection.pool store) receipt) >>= rightEff
                pure PublishSucceeded
              post _ = modifyIORef' legacyReconciliations (+ 1)
          rows <- run (listOutbox "shinzui/shikigami")
          length rows @?= 2
          template <- case rows of first : _ -> pure first; _ -> fail "missing tracker rows"
          let sinkRow = template {event = template.event {Event.destination = "shikigami.sink.v1", Event.messageId = "legacy-delivered"}}
          outcome <- run (publishTrackerRow (Just host) legacy sinkRow)
          outcome @?= PublishSucceeded
          reconcilePublishedRow post sinkRow
          outcomes <- newIORef []
          _ <-
            run
              ( publishClaimedOutbox
                  ( \batch -> forM batch \row -> do
                      outcome' <- publishTrackerRow (Just host) legacy row
                      liftIO (modifyIORef' outcomes (<> [(row, outcome')]))
                      pure (row.outboxId, outcome')
                  )
                  defaultPublishOptions
                  Nothing
              )
          retained <- readIORef outcomes
          map snd retained @?= [PublishSucceeded, PublishSucceeded]
          forM_ retained \(row, result) -> when (result == PublishSucceeded) (reconcilePublishedRow post row)
          readIORef legacyCalls >>= (@?= 1)
          readIORef legacyReconciliations >>= (@?= 1)
          Delivery.lookupDelivery (Connection.pool store) receipt.receiptKey >>= (@?= Right (Just receipt))
          delivered <- right =<< run (S.inspectPublications host objective.objectiveId (key "delivered"))
          unknown <- right =<< run (S.inspectPublications host objective.objectiveId (key "unknown"))
          map ((.state) . snd) delivered @?= [Delivered]
          map ((.state) . snd) unknown @?= [Unknown]
          -- A disabled route must never fall through to the legacy publisher.
          _ <- run (publishTrackerRow Nothing legacy template)
          readIORef legacyCalls >>= (@?= 1)
          routes <- run (S.scheduledBindings host Nothing)
          routes @?= Left TrackerDenied
    ]
  where
    observation scope = let snapshot = RemoteSnapshot (instructions "remote") (instructions "guidance") RemoteOpen in TrackerObservation TrackerV1 scope (Just initialRevision) (observationDigest snapshot) snapshot

instructions :: Text -> OT.Instructions
instructions = checked . OT.parseInstructions

key :: Text -> TrackerCoordinate scope
key = checked . parseCoordinate

operation :: Text -> OperationId
operation = checked . parseOperationId

checked :: (Show e) => Either e a -> a
checked = either (error . show) id

right :: (Show e) => Either e a -> IO a
right = either (\err -> assertFailure (show err) >> fail "unreachable") pure

rightEff :: (MonadIO m, Show e) => Either e a -> m a
rightEff = either (liftIO . fail . show) pure
