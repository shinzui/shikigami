{-# LANGUAGE TypeFamilies #-}

-- | Replay-safe delegation capability for Flow bodies.
--
-- The body receives no 'Store' or 'IOE'. Those stay in this interpreter, which
-- routes every operation through the same allow-list, lineage, budget, child
-- journal, and cancellation machinery as imperative agent supervisors.
module Shikigami.Flow.Delegate
  ( Delegate,
    DelegateEnv (..),
    delegate,
    delegateBatch,
    awaitOne,
    awaitAll,
    cancelOnFailure,
    runDelegate,
  )
where

import Data.Aeson (FromJSON, Value)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret, send)
import Keiro.Workflow (Workflow)
import Kiroku.Store.Effect (Store)
import Shikigami.Agent.Decl (AgentDecl)
import Shikigami.Agent.Delegate (Delegated, DelegationRequest)
import Shikigami.Agent.Delegate qualified as AgentDelegate
import Shikigami.Agent.Delegate.Context (DelegateCtx)
import Shikigami.Directory (DirectoryHandle)
import Shikigami.Router.Catalog (CandidateCatalog)

data DelegateEnv = DelegateEnv
  { agent :: !AgentDecl,
    context :: !DelegateCtx,
    agents :: ![AgentDecl],
    directory :: !DirectoryHandle
  }

data Delegate :: Effect where
  DelegateChild :: Text -> Text -> Value -> Delegate m (Delegated Value)
  DelegateBatch :: CandidateCatalog -> NonEmpty DelegationRequest -> Delegate m (NonEmpty (Delegated Value))
  AwaitOne :: (FromJSON a) => Delegated a -> Delegate m a
  AwaitAll :: (FromJSON a) => [Delegated a] -> Delegate m [Either Text a]
  CancelOnFailure :: (FromJSON a) => [Delegated a] -> Delegate m [Either Text a]

type instance DispatchOf Delegate = Dynamic

-- | Spawn an allow-listed child under a caller-supplied stable call-site key.
delegate :: (Delegate :> es) => Text -> Text -> Value -> Eff es (Delegated Value)
delegate key target payload = send (DelegateChild key target payload)

delegateBatch :: (Delegate :> es) => CandidateCatalog -> NonEmpty DelegationRequest -> Eff es (NonEmpty (Delegated Value))
delegateBatch catalog requests = send (DelegateBatch catalog requests)

awaitOne :: (Delegate :> es, FromJSON a) => Delegated a -> Eff es a
awaitOne delegated = send (AwaitOne delegated)

awaitAll :: (Delegate :> es, FromJSON a) => [Delegated a] -> Eff es [Either Text a]
awaitAll delegated = send (AwaitAll delegated)

cancelOnFailure :: (Delegate :> es, FromJSON a) => [Delegated a] -> Eff es [Either Text a]
cancelOnFailure delegated = send (CancelOnFailure delegated)

runDelegate ::
  (Workflow :> es, Store :> es, IOE :> es) =>
  DelegateEnv ->
  Eff (Delegate : es) a ->
  Eff es a
runDelegate DelegateEnv {agent, context, agents, directory} =
  interpret \_ -> \case
    DelegateChild key target payload -> AgentDelegate.delegate agents directory agent context key target payload
    DelegateBatch catalog requests -> AgentDelegate.delegateBatch agents directory agent context catalog requests
    AwaitOne delegated -> AgentDelegate.awaitDelegated delegated
    AwaitAll delegated -> AgentDelegate.awaitAllDelegated delegated
    CancelOnFailure delegated -> AgentDelegate.cancelSiblingsOnFailure delegated
