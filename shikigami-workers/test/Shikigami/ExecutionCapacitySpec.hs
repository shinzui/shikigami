module Shikigami.ExecutionCapacitySpec (tests, capacityClaimProcess) where

import Control.Concurrent.Async (concurrently)
import Control.Concurrent.MVar
import Data.Aeson qualified as Aeson
import Data.Either (rights)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Hasql.Transaction (Transaction)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Capacity
import Shikigami.Execution.Claim
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
processRace fixture = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  executable <- getExecutablePath
  let env = AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing
      child ticket =
        (proc executable ["--capacity-claim", ticket])
          { env = Just [("SHIKIGAMI_CAPACITY_CONNECTION", Text.unpack connection)],
            std_in = CreatePipe,
            std_out = CreatePipe,
            std_err = Inherit
          }
  register env "root-a" "a"
  register env "root-b" "b"
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
          length (filter (== "deferred") answers) @?= 1
          current <- right =<< run env inspectTx
          current.active @?= 1
          hPutStrLn aInput "stop"
          hPutStrLn bInput "stop"
          waitForProcess aProcess >>= (@?= ExitSuccess)
          waitForProcess bProcess >>= (@?= ExitSuccess)
          final <- right =<< run env inspectTx
          final.active @?= 0
        _ -> assertFailure "capacity fixture did not acquire its private pipes"
  case completed of Just () -> pure (); Nothing -> assertFailure "capacity process race exceeded its bounded deadline"
