{-# LANGUAGE DataKinds #-}

-- | The smallest flow that reaches the governed child-run machinery: it
-- delegates the triggering payload to one statically named agent and returns
-- that child's result. The target and the call-site key are literals of the
-- flow, never payload data.
module FlowPack.Examples.Body.DelegationProof (delegationProof) where

import Data.Aeson (Value)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Shikigami.Agent.Name (agentNameFromNonEmpty)
import Shikigami.Flow.Sdk

delegationProof :: (Delegate :> es) => Value -> Eff es Value
delegationProof payload = do
  child <- delegate (declarationCoordinate "examples-web-researcher") (agentNameFromNonEmpty ('w' :| "eb-researcher")) payload
  awaitOne child
