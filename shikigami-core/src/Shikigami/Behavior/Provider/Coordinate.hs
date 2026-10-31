{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Exact foreign provider tuple coordinates. The SDK/protocol owns their
-- vocabulary; scopes retain meaning without inventing syntax or allocation.
module Shikigami.Behavior.Provider.Coordinate
  ( ProviderCoordinate,
    providerCoordinate,
    providerCoordinateText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Text (Text)
import GHC.TypeLits (Symbol)

type role ProviderCoordinate nominal

newtype ProviderCoordinate (scope :: Symbol) = ProviderCoordinate Text
  deriving stock (Eq, Ord, Show)

-- | Total capture of the exact SDK or protocol value, including opaque custom
-- surfaces. This value alone supplies no model/profile/transport authority.
providerCoordinate :: Text -> ProviderCoordinate scope
providerCoordinate = ProviderCoordinate

providerCoordinateText :: ProviderCoordinate scope -> Text
providerCoordinateText (ProviderCoordinate value) = value

instance ToJSON (ProviderCoordinate scope) where
  toJSON = toJSON . providerCoordinateText
  toEncoding = toEncoding . providerCoordinateText

instance FromJSON (ProviderCoordinate scope) where
  parseJSON = withText "provider coordinate" (pure . providerCoordinate)
