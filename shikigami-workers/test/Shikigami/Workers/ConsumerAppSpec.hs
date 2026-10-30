module Shikigami.Workers.ConsumerAppSpec (tests) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async qualified as Async
import Control.Exception (IOException, SomeException, fromException, try)
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Effectful (IOE, liftIO, runEff, (:>))
import Effectful.Exception qualified as Exception
import Kafka.Consumer (RdKafkaRespErrT (RdKafkaRespErrAllBrokersDown, RdKafkaRespErrFatal, RdKafkaRespErrSaslAuthenticationFailed))
import Kafka.Types (KafkaError (..))
import Keiro.PGMQ (JobTuning (..))
import Shibuya (ProcessorFailure (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (listAdapter)
import Shibuya.App qualified as Shibuya
import Shibuya.Core.Ack (AckDecision (AckOk))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (DeliveryStatus (..), Ingested (..), Message (..), mkIngested)
import Shibuya.Core.Types (Envelope (..), MessageId (..), mkEnvelope)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Shikigami.Trigger.Consumer (kafkaReconnectAllowed)
import Shikigami.Workers.ConsumerApp (ConsumerProcessorFailure, consumerAppConfig, withConsumerApp)
import Shikigami.Workers.Registry (queueTuningFor)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "ConsumerApp"
    [ testCase "Kafka deterministic and authentication failures do not reconnect forever" do
        map kafkaReconnectAllowed [KafkaBadConfiguration, KafkaBadSpecification "invalid", KafkaResponseError RdKafkaRespErrFatal, KafkaResponseError RdKafkaRespErrSaslAuthenticationFailed] @?= replicate 4 False
        kafkaReconnectAllowed (KafkaResponseError RdKafkaRespErrAllBrokersDown) @?= True,
      testCase "queue policy rejects nonpositive and overflowing timeouts before acquisition" do
        assertBool "zero timeout" (isLeft (queueTuningFor 0))
        assertBool "negative timeout" (isLeft (queueTuningFor (-1)))
        assertBool "oversized timeout" (isLeft (queueTuningFor 2147483647)),
      testCase "queued lease covers the configured five-minute attempt and bounded intake" do
        case queueTuningFor 300 of
          Left failure -> assertFailure (show failure)
          Right tuning -> do
            assertBool "two waiting attempt windows remain visible only afterwards" (tuning.visibilityTimeout > 600)
            tuning.batchSize @?= 1,
      testCase "current deliveries finalize once and superseded deliveries do no work" $ within do
        handled <- newIORef []
        finalized <- newIORef []
        stopped <- newIORef (0 :: Int)
        let delivery name status =
              (mkIngested (mkEnvelope (MessageId name) name) (AckHandle (\_ -> liftIO (modifyIORef' finalized (<> [name])))))
                { deliveryStatus = pure status
                }
        result <-
          runEff $ runTracingNoop do
            let adapter = (listAdapter [delivery "old" DeliverySuperseded, delivery "current" DeliveryCurrent]) {shutdown = liftIO (modifyIORef' stopped (+ 1))}
                processor = Shibuya.mkProcessor adapter (\message -> liftIO (modifyIORef' handled (<> [message.envelope.payload])) >> pure AckOk)
            withConsumerApp consumerAppConfig [(Shibuya.ProcessorId "admission", processor)] Shibuya.waitApp
        result @?= Right ()
        readIORef handled >>= (@?= ["current"])
        readIORef finalized >>= (@?= ["current"])
        readIORef stopped >>= (@?= 1),
      testCase "permanent finalization failure reaches process supervision after cleanup" $ within do
        handled <- newIORef (0 :: Int)
        finalized <- newIORef (0 :: Int)
        stopped <- newIORef (0 :: Int)
        result <-
          Async.withAsync
            ( runEff $ runTracingNoop do
                let delivery = mkIngested (mkEnvelope (MessageId "finalizer") ()) (AckHandle (\_ -> liftIO (modifyIORef' finalized (+ 1)) >> Exception.throwIO (userError "injected finalizer failure")))
                    adapter = (listAdapter [delivery]) {shutdown = liftIO (modifyIORef' stopped (+ 1))}
                    processor = Shibuya.mkProcessor adapter (\_ -> liftIO (modifyIORef' handled (+ 1)) >> pure AckOk)
                withConsumerApp consumerAppConfig [(Shibuya.ProcessorId "finalizer", processor)] Shibuya.waitApp
            )
            Async.waitCatch
        assertBool "failed processor must escape, not reconnect gracefully" (case result of Left failure -> isProcessorFailure failure; _ -> False)
        readIORef handled >>= (@?= 1)
        readIORef finalized >>= (@?= 4)
        readIORef stopped >>= (@?= 1),
      testCase "cancellation joins application cleanup exactly once" $ within do
        entered <- newEmptyMVar
        held <- newEmptyMVar
        stopped <- newIORef (0 :: Int)
        worker <-
          Async.async $
            runEff $ runTracingNoop do
              let adapter = emptyAdapter (modifyIORef' stopped (+ 1))
              withConsumerApp consumerAppConfig [(Shibuya.ProcessorId "cancelled", Shibuya.mkProcessor adapter (const (pure AckOk)))] \_ -> do
                liftIO (putMVar entered ())
                liftIO (takeMVar held :: IO ())
        takeMVar entered
        Async.cancel worker
        result <- Async.waitCatch worker
        assertBool "cancellation propagates" (case result of Left _ -> True; _ -> False)
        readIORef stopped >>= (@?= 1),
      testCase "callback failure releases its application" $ within do
        stopped <- newIORef (0 :: Int)
        result <-
          try @IOException $
            runEff $ runTracingNoop do
              let adapter = emptyAdapter (modifyIORef' stopped (+ 1))
              withConsumerApp consumerAppConfig [(Shibuya.ProcessorId "callback", Shibuya.mkProcessor adapter (const (pure AckOk)))] \_ ->
                Exception.throwIO (userError "injected callback failure") >> pure ()
        assertBool "callback failure propagates" (case result of Left _ -> True; _ -> False)
        readIORef stopped >>= (@?= 1),
      testCase "cancellation drains admitted work before returning ownership" $ within do
        entered <- newEmptyMVar
        released <- newEmptyMVar
        finished <- newIORef False
        finalized <- newIORef (0 :: Int)
        stopped <- newIORef (0 :: Int)
        let consume = runEff $ runTracingNoop do
              let delivery = mkIngested (mkEnvelope (MessageId "draining") ()) (AckHandle (\_ -> liftIO (modifyIORef' finalized (+ 1))))
                  adapter = (listAdapter [delivery]) {shutdown = liftIO (modifyIORef' stopped (+ 1) >> putMVar released ())}
                  handler _ = do
                    liftIO (putMVar entered ())
                    liftIO (takeMVar released)
                    liftIO (modifyIORef' finished (const True))
                    pure AckOk
              withConsumerApp consumerAppConfig [(Shibuya.ProcessorId "draining", Shibuya.mkProcessor adapter handler)] Shibuya.waitApp
        Async.withAsync consume \worker -> do
          takeMVar entered
          Async.cancel worker
          result <- Async.waitCatch worker
          assertBool "consumer cancellation propagates" (case result of Left _ -> True; _ -> False)
        readIORef finished >>= (@?= True)
        readIORef finalized >>= (@?= 1)
        readIORef stopped >>= (@?= 1),
      testCase "cleanup failure propagates after one cleanup attempt" $ within do
        stopped <- newIORef (0 :: Int)
        result <- try @IOException $ runEff $ runTracingNoop do
          let adapter = emptyAdapter (modifyIORef' stopped (+ 1) >> ioError (userError "injected cleanup failure"))
          withConsumerApp consumerAppConfig [(Shibuya.ProcessorId "cleanup", Shibuya.mkProcessor adapter (const (pure AckOk)))] Shibuya.waitApp
        assertBool "cleanup failure is not graceful success" (case result of Left _ -> True; _ -> False)
        readIORef stopped >>= (@?= 1),
      testCase "deterministic invalid configuration acquires no application" $ within do
        entered <- newIORef False
        stopped <- newIORef (0 :: Int)
        result <-
          runEff $ runTracingNoop do
            let adapter = emptyAdapter (modifyIORef' stopped (+ 1))
            withConsumerApp consumerAppConfig {Shibuya.inboxSize = 0} [(Shibuya.ProcessorId "invalid", Shibuya.mkProcessor adapter (const (pure AckOk)))] (\_ -> liftIO (modifyIORef' entered (const True)))
        assertBool "configuration failure remains typed" (case result of Left _ -> True; _ -> False)
        readIORef entered >>= (@?= False)
        readIORef stopped >>= (@?= 0)
    ]

within :: IO () -> IO ()
within action = timeout 5_000_000 action >>= maybe (assertFailure "consumer lifecycle timed out") pure

emptyAdapter :: (IOE :> es) => IO () -> Adapter es ()
emptyAdapter cleanup = (listAdapter []) {shutdown = liftIO cleanup}

isProcessorFailure :: SomeException -> Bool
isProcessorFailure failure
  | Just (_ :: ConsumerProcessorFailure) <- fromException failure = True
  | Just (ProcessorFailure _ _) <- fromException failure = True
  | Just (Async.ExceptionInLinkedThread _ inner) <- fromException failure = isProcessorFailure inner
  | otherwise = False
