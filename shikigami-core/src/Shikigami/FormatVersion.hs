{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | A closed first-version format selector, scoped to its owning protocol.
-- The number is a wire representation rather than an arithmetic domain.
module Shikigami.FormatVersion (FormatVersion (V1)) where

import Data.Aeson (FromJSON (..), ToJSON (..))
import GHC.TypeLits (Symbol)

type role FormatVersion nominal

data FormatVersion (scope :: Symbol) = V1
  deriving stock (Eq, Ord)

instance Show (FormatVersion scope) where
  show V1 = "1"

instance ToJSON (FormatVersion scope) where
  toJSON V1 = toJSON (1 :: Integer)
  toEncoding V1 = toEncoding (1 :: Integer)

instance FromJSON (FormatVersion scope) where
  parseJSON value = do
    version <- parseJSON @Integer value
    if version == 1 then pure V1 else fail "unsupported format version"
