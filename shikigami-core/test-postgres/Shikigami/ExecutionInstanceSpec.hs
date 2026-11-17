-- | ADR 0132: a runtime permit is reclaimable once its claimant's process
-- instance no longer holds its session lock.
module Shikigami.ExecutionInstanceSpec (tests) where

import Control.Concurrent (threadDelay)
import Hasql.Transaction (Transaction)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Transaction (runTransaction)
import Shikigami.App (AppEnv (..), noopTracer, runAppIO)
import Shikigami.Execution.Capacity
import Shikigami.Execution.Claim
import Shikigami.Execution.Instance
import Shikigami.Migrations.TestSupport (DatabaseFixture, withShikigamiFreshDatabase)
import Shikigami.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: DatabaseFixture -> TestTree
tests fixture =
  testGroup
    "ExecutionInstance"
    [ testCase "a stopped instance's permit is reclaimed and a live instance's is kept" $ withInstances fixture \env connection -> do
        live <- enrolled =<< enrollExecutorInstance connection (const (pure ()))
        killed <- enrolled =<< enrollExecutorInstance connection (const (pure ()))
        assertBool "instances are distinct" (live.executor /= killed.executor)
        configure env 3
        forM_ ["live", "killed", "bare"] \ticket -> right =<< run env (registerTx ("root-" <> ticket) ticket)
        admit env "live" (Just live.executor) >>= (@?= True)
        admit env "killed" (Just killed.executor) >>= (@?= True)
        admit env "bare" Nothing >>= (@?= True)
        stopped env >>= (@?= [])
        -- Closing the session is what PostgreSQL sees when a process dies.
        releaseExecutorInstance killed
        eventually (stopped env) (== ["killed"]) >>= (@?= ["killed"])
        right =<< run env (reclaimTx "killed")
        snapshot <- right =<< run env inspectTx
        snapshot.active @?= 2
        stopped env >>= (@?= [])
        -- The stopped owner's late settlement, or a second reclamation, finds
        -- the permit already settled.
        right =<< run env (releaseTx "killed" (Just (owner "killed")))
        right =<< run env (reclaimTx "killed")
        releaseExecutorInstance live,
      testCase "the process instance is held while executors are in flight and reused after" $ withInstances fixture \env connection -> do
        right =<< run env (registerTx "root" "process")
        outer <- withExecutorInstance connection \claimant -> do
          held <- maybe (assertFailure "no instance was held") pure claimant
          nested <- withExecutorInstance connection pure
          nested @?= Just held
          admit env "process" (Just held) >>= (@?= True)
          -- A permit of a running executor is never reclaimable.
          stopped env >>= (@?= [])
          pure held
        -- With no executor in flight the lock is free: a permit the process
        -- left behind is reclaimable.
        eventually (stopped env) (== ["process"]) >>= (@?= ["process"])
        again <- withExecutorInstance connection pure
        again @?= Just outer
        withExecutorInstance "" pure >>= (@?= Nothing)
    ]

withInstances :: DatabaseFixture -> (AppEnv -> Text -> IO a) -> IO a
withInstances fixture use = withShikigamiFreshDatabase fixture \connection -> do
  tracer <- noopTracer
  use (AppEnv (defaultConnectionSettings connection) tracer Nothing Nothing) connection

run :: AppEnv -> Transaction a -> IO a
run env action = runAppIO env (runTransaction action) >>= either (assertFailure . show) pure

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

enrolled :: Either Text EnrolledInstance -> IO EnrolledInstance
enrolled = either (assertFailure . show) pure

owner :: Text -> ClaimOwner
owner = either (error . show) id . parseClaimOwner

stopped :: AppEnv -> IO [Text]
stopped env = right =<< run env stoppedTicketsTx

admit :: AppEnv -> Text -> Maybe ExecutorInstance -> IO Bool
admit env ticket claimant = right =<< run env (admitTx ticket (owner ticket) Nothing claimant)

configure :: AppEnv -> Int -> IO ()
configure env value = do
  current <- right =<< run env inspectTx
  bound <- right (parseCapacityLimit value)
  right =<< run env (reconfigureTx current.revision bound)

-- PostgreSQL releases a closed session's locks when its backend exits, which
-- the client does not wait for.
eventually :: IO a -> (a -> Bool) -> IO a
eventually probe accepted = go (50 :: Int)
  where
    go remaining = do
      value <- probe
      if accepted value || remaining <= 0 then pure value else threadDelay 100000 >> go (remaining - 1)
