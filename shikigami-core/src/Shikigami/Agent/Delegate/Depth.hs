-- | Nominal scalar owned by the agent execution boundary.
module Shikigami.Agent.Delegate.Depth (DelegationDepth (..), depthInt) where

import Data.Aeson (FromJSON (..), ToJSON)

-- | Construction from trusted application values is explicit. Wire ingress
-- validates the scalar before it reaches the durable execution boundary.
newtype DelegationDepth = DelegationDepth Int
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

depthInt :: DelegationDepth -> Int
depthInt (DelegationDepth value) = value

instance FromJSON DelegationDepth where
  parseJSON json = do
    value <- parseJSON json
    if value >= 0 then pure (DelegationDepth value) else fail "delegation depth must not be negative"
