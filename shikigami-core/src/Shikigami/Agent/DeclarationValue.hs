{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Manifest claims keep their spelling until the owning directory, registry
-- or external service resolves them. Quantities and execution policy are typed
-- before entering those adapters.
module Shikigami.Agent.DeclarationValue
  ( DeclarationCoordinate,
    declarationCoordinate,
    declarationCoordinateText,
    AgentEnablement (..),
    agentEnablement,
    agentEnabled,
    SignalImportance,
    parseSignalImportance,
    signalImportanceInt,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall (Decoder (..), FromDhall (..))
import Dhall qualified
import GHC.TypeLits (Symbol)
import Numeric.Natural (Natural)

type role DeclarationCoordinate nominal

newtype DeclarationCoordinate (scope :: Symbol) = DeclarationCoordinate Text
  deriving stock (Eq, Ord, Show)

declarationCoordinate :: Text -> DeclarationCoordinate scope
declarationCoordinate = DeclarationCoordinate

declarationCoordinateText :: DeclarationCoordinate scope -> Text
declarationCoordinateText (DeclarationCoordinate value) = value

instance ToJSON (DeclarationCoordinate scope) where
  toJSON = toJSON . declarationCoordinateText
  toEncoding = toEncoding . declarationCoordinateText

instance FromJSON (DeclarationCoordinate scope) where
  parseJSON value = DeclarationCoordinate <$> parseJSON value

instance FromDhall (DeclarationCoordinate scope) where
  autoWith _ = DeclarationCoordinate <$> Dhall.strictText

data AgentEnablement = AgentEnabled | AgentDisabled deriving stock (Eq, Show)

agentEnablement :: Bool -> AgentEnablement
agentEnablement enabled = if enabled then AgentEnabled else AgentDisabled

agentEnabled :: AgentEnablement -> Bool
agentEnabled AgentEnabled = True
agentEnabled AgentDisabled = False

instance ToJSON AgentEnablement where
  toJSON = toJSON . agentEnabled
  toEncoding = toEncoding . agentEnabled

instance FromJSON AgentEnablement where parseJSON value = agentEnablement <$> parseJSON value

instance FromDhall AgentEnablement where autoWith _ = agentEnablement <$> Dhall.bool

newtype SignalImportance = SignalImportance Int deriving stock (Eq, Ord, Show)

parseSignalImportance :: Natural -> Either Text SignalImportance
parseSignalImportance value
  | value <= 100 = Right (SignalImportance (fromIntegral value))
  | otherwise = Left "signal importance must be between 0 and 100"

signalImportanceInt :: SignalImportance -> Int
signalImportanceInt (SignalImportance value) = value

instance ToJSON SignalImportance where
  toJSON = toJSON . signalImportanceInt
  toEncoding = toEncoding . signalImportanceInt

instance FromJSON SignalImportance where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . parseSignalImportance

instance FromDhall SignalImportance where
  autoWith _ =
    let Decoder {extract = readNatural, expected} = Dhall.natural
     in Decoder
          { extract = \expression -> case Dhall.toMonadic (readNatural expression) of
              Left problem -> Dhall.fromMonadic (Left problem)
              Right value -> either Dhall.extractError pure (parseSignalImportance value),
            expected
          }
