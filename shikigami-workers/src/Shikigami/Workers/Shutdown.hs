-- | Supported process signals for long-running worker roles.
module Shikigami.Workers.Shutdown
  ( withGracefulShutdown,
  )
where

import Control.Concurrent (myThreadId, throwTo)
import Control.Exception
  ( Exception (fromException, toException),
    asyncExceptionFromException,
    asyncExceptionToException,
    bracket,
    catch,
  )
import Control.Monad (void)
import System.Posix.Signals
  ( Handler (CatchOnce),
    installHandler,
    keyboardSignal,
    softwareTermination,
  )

-- | A private asynchronous exception used only to unwind resource brackets.
data GracefulShutdown = GracefulShutdown
  deriving stock (Show)

instance Exception GracefulShutdown where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | Convert SIGINT and SIGTERM into a clean unwind of the main worker thread.
--
-- Only 'GracefulShutdown' is consumed. Loop failures and every other exception
-- retain the fail-fast behavior documented by worker supervision.
withGracefulShutdown :: IO () -> IO ()
withGracefulShutdown action = do
  owner <- myThreadId
  bracket (install owner) restore (const action)
    `catch` \GracefulShutdown -> pure ()
  where
    install owner = do
      term <- installHandler softwareTermination (CatchOnce (throwTo owner GracefulShutdown)) Nothing
      interrupt <- installHandler keyboardSignal (CatchOnce (throwTo owner GracefulShutdown)) Nothing
      pure (term, interrupt)

    restore (term, interrupt) = do
      void (installHandler softwareTermination term Nothing)
      void (installHandler keyboardSignal interrupt Nothing)
