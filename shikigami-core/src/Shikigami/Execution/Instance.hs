-- | The identity under which a process claims accepted attempts (ADR 0132).
--
-- A process enrolls one instance per database. While any of its executors is
-- in flight, it holds a PostgreSQL session advisory lock on that instance on a
-- dedicated connection. PostgreSQL releases the lock when that session ends,
-- including when the process dies. Another process that can take the lock
-- therefore knows, as a database fact rather than from a clock or a lease, that
-- no executor of the instance is running, and "Shikigami.Execution.Capacity"
-- may reclaim the runtime permits it left behind.
--
-- The lock is held only while executors are in flight, so an idle process
-- holds no extra connection. Re-taking it for the next executor is safe:
-- permits are stamped with the instance only after the lock is held.
--
-- If the lock connection stops answering, it is dropped and the next executor
-- re-takes the lock on a fresh connection. Executors already running finish
-- within their run timeout; their permits may be reclaimed in the meantime.
module Shikigami.Execution.Instance
  ( ExecutorInstance,
    executorInstanceNumber,
    instanceLockNamespace,
    withExecutorInstance,
    EnrolledInstance (..),
    enrollExecutorInstance,
    releaseExecutorInstance,
  )
where

import Contravariant.Extras (contrazip2)
import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, takeMVar)
import Control.Exception (SomeException, bracket, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Bifunctor (first)
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Foldable (traverse_)
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Hasql.Connection (Connection)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Shikigami.Prelude
import System.IO (stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)

-- | An enrolled instance. Its number keys both its row in
-- @shikigami.execution_instances@ and its advisory lock.
newtype ExecutorInstance = ExecutorInstance Int32
  deriving stock (Eq, Ord, Show)

executorInstanceNumber :: ExecutorInstance -> Int32
executorInstanceNumber (ExecutorInstance number) = number

-- | The advisory lock class that instance locks use ("SHKE"). Capacity
-- reclamation probes the same pair.
instanceLockNamespace :: Int32
instanceLockNamespace = 1397246789

-- | A held instance lock: the instance, the dedicated connection holding its
-- lock and the watchdog that notices when that connection fails.
data EnrolledInstance = EnrolledInstance
  { executor :: !ExecutorInstance,
    connection :: !Connection,
    watchdog :: !ThreadId
  }

-- | Enroll a new instance and hold its lock until 'releaseExecutorInstance' or
-- the end of the process. @onLost@ runs once if the lock connection stops
-- answering. 'withExecutorInstance' is the executor's entry point; this is for
-- callers that manage the lifetime themselves.
enrollExecutorInstance :: Text -> (EnrolledInstance -> IO ()) -> IO (Either Text EnrolledInstance)
enrollExecutorInstance connectionString = holdLock connectionString Nothing

-- | Stop the watchdog and close the lock connection, freeing the lock.
releaseExecutorInstance :: EnrolledInstance -> IO ()
releaseExecutorInstance held = do
  killThread held.watchdog
  Connection.release held.connection

-- | Run an executor under this process's instance for one database, holding
-- the instance lock for the duration. The action receives 'Nothing' when no
-- instance can be held (an empty connection string or a failed enrollment);
-- its claims then carry no instance and only settlement releases them.
withExecutorInstance :: Text -> (Maybe ExecutorInstance -> IO a) -> IO a
withExecutorInstance connectionString action
  | Text.null connectionString = action Nothing
  | otherwise = bracket (enter connectionString) (traverse_ (const (leave connectionString))) action

-- The process's instance for one database, the lock while held, and how many
-- executors are in flight under it.
data Slot = Slot
  { number :: !(Maybe ExecutorInstance),
    holder :: !(Maybe EnrolledInstance),
    users :: !Int
  }

emptySlot :: Slot
emptySlot = Slot Nothing Nothing 0

enter :: Text -> IO (Maybe ExecutorInstance)
enter connectionString = modifyMVar processInstances \slots -> do
  let slot = Map.findWithDefault emptySlot connectionString slots
  case slot.holder of
    Just held -> pure (Map.insert connectionString slot {users = slot.users + 1} slots, Just held.executor)
    Nothing -> do
      result <- try @SomeException (holdLock connectionString slot.number (lost connectionString))
      case result of
        Right (Right held) -> pure (Map.insert connectionString (Slot (Just held.executor) (Just held) (slot.users + 1)) slots, Just held.executor)
        Right (Left problem) -> refused problem >> pure (slots, Nothing)
        Left exception -> refused ("execution instance enrollment failed: " <> Text.pack (show exception)) >> pure (slots, Nothing)
  where
    refused problem = report "execution.instance.refused" [("error", Aeson.toJSON problem)]

leave :: Text -> IO ()
leave connectionString = modifyMVar_ processInstances \slots -> case Map.lookup connectionString slots of
  Nothing -> pure slots
  Just slot
    | slot.users <= 1 -> do
        traverse_ releaseExecutorInstance slot.holder
        pure (Map.insert connectionString slot {holder = Nothing, users = 0} slots)
    | otherwise -> pure (Map.insert connectionString slot {users = slot.users - 1} slots)

-- A failed lock connection is dropped; the next executor re-takes the lock.
lost :: Text -> EnrolledInstance -> IO ()
lost connectionString held = modifyMVar_ processInstances \slots -> case Map.lookup connectionString slots of
  Just slot
    | Just current <- slot.holder,
      current.watchdog == held.watchdog -> do
        Connection.release held.connection
        pure (Map.insert connectionString slot {holder = Nothing} slots)
  _ -> pure slots

-- Take the lock for an existing instance, or enroll a new one, on a fresh
-- connection, and start its watchdog.
holdLock :: Text -> Maybe ExecutorInstance -> (EnrolledInstance -> IO ()) -> IO (Either Text EnrolledInstance)
holdLock connectionString existing onLost =
  Connection.acquire (Settings.connectionString connectionString) >>= \case
    Left problem -> pure (Left ("execution instance connection failed: " <> Text.pack (show problem)))
    Right connection -> do
      held <- Connection.use connection do
        number <- maybe (Session.statement () enrollInstance) (pure . executorInstanceNumber) existing
        Session.statement (instanceLockNamespace, number) holdInstanceLock
        pure number
      case held of
        Left problem -> do
          Connection.release connection
          pure (Left ("execution instance lock failed: " <> Text.pack (show problem)))
        Right number -> do
          -- The watchdog reports its own enrollment, so it waits for it.
          started <- newEmptyMVar
          watchdog <- forkIO (takeMVar started >>= watch connection)
          let enrolled = EnrolledInstance (ExecutorInstance number) connection watchdog
          putMVar started enrolled
          pure (Right enrolled)
  where
    watch connection held = do
      threadDelay watchdogInterval
      answered <- timeout watchdogInterval (Connection.use connection (Session.statement () ping))
      case answered of
        Just (Right ()) -> watch connection held
        _ -> do
          report "execution.instance.lost" [("instance", Aeson.toJSON (executorInstanceNumber held.executor))]
          onLost held

report :: Text -> [(Text, Aeson.Value)] -> IO ()
report event fields = LazyChar8.hPutStrLn stderr (Aeson.encode (Aeson.object ([("event", Aeson.toJSON event), ("level", "error")] <> map (first Key.fromText) fields)))

-- One slot per database. The registry is process-global because the lock it
-- guards stands for this process's own executors.
processInstances :: MVar (Map Text Slot)
processInstances = unsafePerformIO (newMVar Map.empty)
{-# NOINLINE processInstances #-}

watchdogInterval :: Int
watchdogInterval = 5000000

enrollInstance :: Statement () Int32
enrollInstance = preparable "INSERT INTO shikigami.execution_instances DEFAULT VALUES RETURNING instance_id" E.noParams (D.singleRow (D.column (D.nonNullable D.int4)))

holdInstanceLock :: Statement (Int32, Int32) ()
holdInstanceLock = preparable "SELECT pg_advisory_lock($1,$2)::text" (contrazip2 (E.param (E.nonNullable E.int4)) (E.param (E.nonNullable E.int4))) (void (D.singleRow (D.column (D.nonNullable D.text))))

ping :: Statement () ()
ping = preparable "SELECT 1" E.noParams (void (D.singleRow (D.column (D.nonNullable D.int4))))
