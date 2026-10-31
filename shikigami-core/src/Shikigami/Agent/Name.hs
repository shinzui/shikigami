-- | The nonempty declared name of an agent, preserved without normalization.
module Shikigami.Agent.Name (AgentName, mkAgentName, agentNameFromNonEmpty, agentNameText) where

import Data.Aeson (FromJSON (..), ToJSON, withText)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (Decoder (..), FromDhall (..))
import Dhall qualified

newtype AgentName = AgentName Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON)

mkAgentName :: Text -> Either Text AgentName
mkAgentName value
  | not (Text.null value) = Right (AgentName value)
  | otherwise = Left "agent name must not be empty"

-- | Structural admission for static vocabulary, without an unchecked literal.
agentNameFromNonEmpty :: NonEmpty Char -> AgentName
agentNameFromNonEmpty = AgentName . Text.pack . NonEmpty.toList

agentNameText :: AgentName -> Text
agentNameText (AgentName value) = value

instance FromJSON AgentName where
  parseJSON = withText "agent name" (either (fail . Text.unpack) pure . mkAgentName)

instance FromDhall AgentName where
  autoWith _ =
    let Decoder {extract = extractText, expected = expectedText} = Dhall.strictText
     in Decoder
          { extract = \expression ->
              case Dhall.toMonadic (extractText expression) of
                Left err -> Dhall.fromMonadic (Left err)
                Right value -> either Dhall.extractError pure (mkAgentName value),
            expected = expectedText
          }
