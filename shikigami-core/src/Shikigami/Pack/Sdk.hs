-- | What a pack's interpreter may import beyond "Shikigami.Flow.Sdk"
-- (docs/adr/0129). This module is the whole of @shikigami-core:pack-sdk@.
--
-- A pack's main library depends on this component; its @bodies@ sublibrary
-- does not. That split is the rule that a flow body reaches the world only
-- through capabilities: 'IOE' and 'Store' are nameable here, where the
-- reviewed interpreter lives, and nowhere a body can see.
--
-- The export list is pinned by a golden file and grows by reviewed additions,
-- each for a consumer that exists: a later plan adds the kernel ports and the
-- kernel modules a moved subsystem needs.
module Shikigami.Pack.Sdk
  ( -- * The run a pack interpreter serves
    FlowRunContext (..),

    -- * Interpreting a pack capability
    IOE,
    liftIO,
    interpret,
    reinterpret,

    -- * The store
    Store,
    StoreError,
    Error,
    runTransaction,
    runTransactionNoRetry,

    -- * Logging
    Logger,
    logDebug,
    logInfo,
    logWarn,
    logError,
  )
where

import Effectful (IOE, liftIO)
import Effectful.Dispatch.Dynamic (interpret, reinterpret)
import Effectful.Error.Static (Error)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction, runTransactionNoRetry)
import Shikigami.Flow.Pack (FlowRunContext (..))
import Shikigami.Log (Logger, logDebug, logError, logInfo, logWarn)
