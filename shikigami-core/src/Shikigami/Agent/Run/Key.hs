-- | Nominal scalar owned by the agent execution boundary.
module Shikigami.Agent.Run.Key (RunKey (..), runKeyText) where

import Data.Aeson (FromJSON (..), ToJSON)
import Data.Text (Text)
import Data.Text qualified as Text

-- | Construction from trusted application values is explicit. Wire ingress
-- validates the scalar before it reaches the durable execution boundary.
newtype RunKey = RunKey Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

runKeyText :: RunKey -> Text
runKeyText (RunKey value) = value

instance FromJSON RunKey where
  parseJSON json = do
    value <- parseJSON json
    if not (Text.null value) then pure (RunKey value) else fail "run key must not be empty"
