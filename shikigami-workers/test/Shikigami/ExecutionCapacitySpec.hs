module Shikigami.ExecutionCapacitySpec (tests, capacityClaimProcess, rootCapacityClaimProcess) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Concurrent.MVar
import Data.Aeson qualified as Aeson
import Data.Either (rights)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Capacity
import Shikigami.Execution.Claim
import Shikigami.Execution.Coordinate (executionCoordinate)
import Shikigami.Execution.Counter (noAttempts)
import Shikigami.Execution.Counter qualified
import Shikigami.Execution.Identity qualified
import Shikigami.Execution.Quantity (oneAmount, zeroAmount)
import Shikigami.Execution.Resources qualified as R
import Shikigami.Execution.ResourcesStore qualified as Roots
import Shikigami.Fixture.ExecutionIdentity
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Prelude
import Shikigami.StateRevision
import System.Environment (getEnv, getExecutablePath)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (BufferMode (LineBuffering), hGetLine, hPutStrLn, hSetBuffering, stdout)
import System.Process (CreateProcess (..), StdStream (CreatePipe, Inherit), proc, waitForProcess, withCreateProcess)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ExecutionCapacity"
    [ testCase "configuration admits only positive bounded capacity" do
        forM_ [-1, 0, 129] \value -> assertBool "refused" (null (rights [parseCapacityLimit value]))
        validateHeadroom 10 defaultRuntimeLimits @?= Right ()
        assertBool "headroom enforced" (case validateHeadroom 5 defaultRuntimeLimits of Left _ -> True; _ -> False)
        assertBool "invalid JSON refused" (case Aeson.fromJSON (toJSON (0 :: Int)) :: Aeson.Result CapacityLimit of Aeson.Error _ -> True; _ -> False),
      testCase "stale replica configuration cannot undo a newer capacity change" $ withCapacity fixture \a _ -> do
        let raised = defaultRuntimeLimits & #execution .~ (either (error . show) id (parseCapacityLimit 2))
        run a (configureTx raised) >>= (@?= Right ())
        run a (configureTx defaultRuntimeLimits) >>= (@?= Left CapacityConflict)
        current <- right =<< run a inspectTx
        run a (configureTx (defaultRuntimeLimits & #expectedRevision .~ Just current.revision)) >>= (@?= Right ())
        run a (configureTx raised) >>= (@?= Left CapacityConflict)
        final <- right =<< run a inspectTx
        capacityLimit final.maximum @?= 1,
      testCase "independent executions enter useful work before either completes" $ withCapacity fixture \a b -> do
        register a "root-a" "worker-call"
        register a "root-b" "coordinator-call"
        configure a 2
        claim a "worker-call" "worker-call" Nothing >>= (@?= True)
        claim b "coordinator-call" "coordinator-call" Nothing >>= (@?= True)
        entered <- newEmptyMVar
        release <- newEmptyMVar
        let execute env ticket = do
              start <- getCurrentTime
              putMVar entered ticket
              readMVar release
              end <- getCurrentTime
              settle env ticket ticket
              pure (start, end)
        result <-
          timeout 5000000 $
            concurrently
              (concurrently (execute a "worker-call") (execute b "coordinator-call"))
              (takeMVar entered >> takeMVar entered >> putMVar release ())
        case result of
          Just (((aStart, aEnd), (bStart, bEnd)), ()) -> assertBool "actual execution intervals overlap" (max aStart bStart < min aEnd bEnd)
          Nothing -> assertFailure "both useful operations did not enter before the bounded barrier deadline",
      testCase "an unrelated ready root advances within one admission round" $ withCapacity fixture \a _ -> do
        register a "large" "large-1"
        register a "large" "large-2"
        register a "large" "large-3"
        register a "unrelated" "small"
        claim a "large-1" "one" Nothing >>= (@?= True)
        settle a "large-1" "one"
        claim a "large-2" "two" Nothing >>= (@?= False)
        claim a "small" "small-owner" Nothing >>= (@?= True)
        settle a "small" "small-owner"
        claim a "large-2" "two" Nothing >>= (@?= True),
      testCase "lower capacity drains without replacing live owners or admitting excess work" $ withCapacity fixture \a _ -> do
        register a "root-a" "a"
        register a "root-b" "b"
        register a "root-c" "c"
        configure a 2
        claim a "a" "owner-a" Nothing >>= (@?= True)
        claim a "b" "owner-b" Nothing >>= (@?= True)
        configure a 1
        claim a "c" "owner-c" Nothing >>= (@?= False)
        claim a "a" "replacement" Nothing >>= (@?= False)
        settle a "a" "owner-a"
        claim a "c" "owner-c" Nothing >>= (@?= False)
        settle a "b" "owner-b"
        claim a "c" "owner-c" Nothing >>= (@?= True)
        current <- right =<< run a inspectTx
        current.active @?= 1
        capacityLimit current.maximum @?= 1,
      testCase "separate runtime connections cannot race past the shared last slot" $ withCapacity fixture \a b -> do
        register a "one" "first"
        register a "two" "second"
        (left, rightResult) <- concurrently (claim a "first" "a" Nothing) (claim b "second" "b" Nothing)
        length (filter id [left, rightResult]) @?= 1
        snapshot <- right =<< run b inspectTx
        snapshot.active @?= 1,
      testCase "two separate runtime processes share one physical admission slot" (processRace fixture),
      testCase "two processes cannot spend a root last slot even with spare global capacity" (processRaceWithRoot True fixture),
      testCase "a permit changes owner only under an explicit expected former claim" $ withCapacity fixture \a _ -> do
        register a "root" "attempt"
        claim a "attempt" "old" Nothing >>= (@?= True)
        claim a "attempt" "new" Nothing >>= (@?= False)
        claim a "attempt" "new" (Just (owner "wrong")) >>= (@?= False)
        claim a "attempt" "new" (Just (owner "old")) >>= (@?= True)
        run a (releaseTx "attempt" (Just (owner "old"))) >>= (@?= Left CapacityConflict)
        settle a "attempt" "new"
    ]

withCapacity :: DatabaseFixture -> (AppEnv -> AppEnv -> IO a) -> IO a
withCapacity fixture use = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  let a = AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing
      b = AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing
  use a b

run :: AppEnv -> Transaction a -> IO a
run env action = runAppIO env (runTransaction action) >>= right

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

owner :: Text -> ClaimOwner
owner = either (error . show) id . parseClaimOwner

register :: AppEnv -> Text -> Text -> IO ()
register env root ticket = right =<< run env (registerTx root ticket)

claim :: AppEnv -> Text -> Text -> Maybe ClaimOwner -> IO Bool
claim env ticket key previous = right =<< run env (admitTx ticket (owner key) previous)

settle :: AppEnv -> Text -> Text -> IO ()
settle env ticket key = right =<< run env (releaseTx ticket (Just (owner key)))

configure :: AppEnv -> Int -> IO ()
configure env value = do
  current <- right =<< run env inspectTx
  bound <- right (parseCapacityLimit value)
  right =<< run env (reconfigureTx current.revision bound)

-- Child mode is used only by this test executable, with a minimal environment
-- containing the disposable database connection and no host credentials.
capacityClaimProcess :: Text -> IO ()
capacityClaimProcess ticket = do
  hSetBuffering stdout LineBuffering
  connection <- Text.pack <$> getEnv "SHIKIGAMI_CAPACITY_CONNECTION"
  tracer <- noopTracer
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing
  putStrLn "ready"
  _ <- getLine
  accepted <- claim env ticket ("process:" <> ticket) Nothing
  putStrLn (if accepted then "granted" else "deferred")
  _ <- getLine
  if accepted then settle env ticket ("process:" <> ticket) else pure ()

processRace :: DatabaseFixture -> IO ()
processRace = processRaceWithRoot False

processRaceWithRoot :: Bool -> DatabaseFixture -> IO ()
processRaceWithRoot rootBound fixture = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  executable <- getExecutablePath
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing
      child ticket =
        (proc executable [if rootBound then "--root-capacity-claim" else "--capacity-claim", ticket])
          { env = Just [("SHIKIGAMI_CAPACITY_CONNECTION", Text.unpack connection)],
            std_in = CreatePipe,
            std_out = CreatePipe,
            std_err = Inherit
          }
  register env "root-a" "a"
  register env "root-b" "b"
  when rootBound do
    configure env 2
    now <- getCurrentTime
    let limits = Map.insert R.ActiveWork (R.Limited oneAmount) (Map.fromList [(dimension, R.ExplicitlyUnbounded) | dimension <- [minBound .. maxBound]])
    _ <- right =<< run env (Roots.enrollRootTx processRoot (R.Envelope limits (addUTCTime 60 now)))
    state <- right =<< run env (Roots.inspectRootTx processRoot)
    _ <- right =<< run env (Roots.reserveOperationsTx processRoot state.revision [R.OperationRequest (fixtureOperationId ("root-race:" <> ticket)) Nothing R.ModelOperation Map.empty (executionCoordinate "root-race/1") | ticket <- ["a", "b"]] now)
    pure ()
  completed <- timeout 10000000 $
    withCreateProcess (child "a") \aIn aOut _ aProcess ->
      withCreateProcess (child "b") \bIn bOut _ bProcess -> case (aIn, aOut, bIn, bOut) of
        (Just aInput, Just aOutput, Just bInput, Just bOutput) -> do
          hSetBuffering aInput LineBuffering
          hSetBuffering bInput LineBuffering
          hGetLine aOutput >>= (@?= "ready")
          hGetLine bOutput >>= (@?= "ready")
          hPutStrLn aInput "go"
          hPutStrLn bInput "go"
          answers <- sequence [hGetLine aOutput, hGetLine bOutput]
          length (filter (== "granted") answers) @?= 1
          length (filter (== (if rootBound then "root-exhausted" else "deferred")) answers) @?= 1
          when rootBound do
            capacityLimit <$> ((.maximum) <$> (right =<< run env inspectTx)) >>= (@?= 2)
            root <- right =<< run env (Roots.inspectRootTx processRoot)
            root.active @?= either (error . show) id (Shikigami.Execution.Counter.parseAttemptCount 1)
            Map.lookup R.ModelAttempts root.usage.held @?= Just oneAmount
          current <- right =<< run env inspectTx
          current.active @?= 1
          hPutStrLn aInput "stop"
          hPutStrLn bInput "stop"
          waitForProcess aProcess >>= (@?= ExitSuccess)
          waitForProcess bProcess >>= (@?= ExitSuccess)
          final <- right =<< run env inspectTx
          final.active @?= 0
          when rootBound do
            root <- right =<< run env (Roots.inspectRootTx processRoot)
            root.active @?= noAttempts
            root.unknown @?= noAttempts
            Map.lookup R.ModelAttempts root.usage.settled @?= Just oneAmount
        _ -> assertFailure "capacity fixture did not acquire its private pipes"
  case completed of Just () -> pure (); Nothing -> assertFailure "capacity process race exceeded its bounded deadline"

processRoot :: Shikigami.Execution.Identity.ExecutionRootId
processRoot = fixtureRootId "cross-process-root-last-slot"

rootCapacityClaimProcess :: Text -> IO ()
rootCapacityClaimProcess ticket = do
  hSetBuffering stdout LineBuffering
  connection <- Text.pack <$> getEnv "SHIKIGAMI_CAPACITY_CONNECTION"
  tracer <- noopTracer
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing
      attempt = fixtureAttemptId ("root-race:" <> ticket)
      begin remaining = do
        now <- getCurrentTime
        answer <-
          right =<< run env do
            root <- Roots.inspectRootTx processRoot
            case root of
              Left err -> pure (Left (Text.pack (show err)))
              Right state -> do
                begun <- Roots.beginAttemptTx processRoot state.revision (R.AttemptRequest attempt (fixtureOperationId ("root-race:" <> ticket)) (Map.fromList [(R.ActiveWork, oneAmount), (R.ModelAttempts, oneAmount), (R.Tokens, zeroAmount), (R.CostMicroUsd, zeroAmount)]) R.EnforcedCeiling) now
                case begun of
                  Left (R.ResourceExhausted R.ActiveWork) -> pure (Right "root-exhausted")
                  Left err -> Tx.condemn >> pure (Left (Text.pack (show err)))
                  Right _ ->
                    admitTx ticket (owner ("process:" <> ticket)) Nothing >>= \case
                      Right True -> pure (Right "granted")
                      Right False -> Tx.condemn >> pure (Right "retry")
                      Left err -> Tx.condemn >> pure (Left (Text.pack (show err)))
        if answer == "retry" && remaining > (0 :: Int) then threadDelay 10000 >> begin (remaining - 1) else pure answer
  putStrLn "ready"
  _ <- getLine
  answer <- begin 100
  putStrLn (Text.unpack answer)
  _ <- getLine
  if answer == "granted"
    then do
      _ <- right =<< run env (Roots.settleAttemptTx processRoot attempt (R.KnownUsage (Map.fromList [(R.Tokens, zeroAmount), (R.CostMicroUsd, zeroAmount)])))
      settle env ticket ("process:" <> ticket)
    else right =<< run env (releaseTx ticket Nothing)
