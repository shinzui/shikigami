-- | Named runtime choices with their historical boolean configuration codecs.
module Shikigami.RuntimePolicy
  ( ManifestStrictness (..),
    manifestStrictness,
    manifestsStrict,
    DefaultModelRequirement (..),
    defaultModelRequirement,
    defaultModelRequired,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))

data ManifestStrictness = StrictManifests | LenientManifests deriving stock (Eq, Show)

manifestStrictness :: Bool -> ManifestStrictness
manifestStrictness value = if value then StrictManifests else LenientManifests

manifestsStrict :: ManifestStrictness -> Bool
manifestsStrict value = value == StrictManifests

instance ToJSON ManifestStrictness where
  toJSON = toJSON . manifestsStrict
  toEncoding = toEncoding . manifestsStrict

instance FromJSON ManifestStrictness where parseJSON value = manifestStrictness <$> parseJSON value

data DefaultModelRequirement = DefaultModelRequired | DefaultModelOptional deriving stock (Eq, Show)

defaultModelRequirement :: Bool -> DefaultModelRequirement
defaultModelRequirement value = if value then DefaultModelRequired else DefaultModelOptional

defaultModelRequired :: DefaultModelRequirement -> Bool
defaultModelRequired value = value == DefaultModelRequired

instance ToJSON DefaultModelRequirement where
  toJSON = toJSON . defaultModelRequired
  toEncoding = toEncoding . defaultModelRequired

instance FromJSON DefaultModelRequirement where parseJSON value = defaultModelRequirement <$> parseJSON value
