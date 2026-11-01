{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Policy quantities and independently granted permissions. The scope names
-- retain units and policy axes without changing the profile's wire format.
module Shikigami.Attestation.PolicyValue
  ( Ceiling,
    mkCeiling,
    ceilingValue,
    Permission (..),
    permissionAllowed,
    permissionFromBool,
    PolicyCoordinate,
    policyCoordinate,
    policyCoordinateText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withBool, withText)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.TypeLits (Symbol)

type role Ceiling nominal nominal

newtype Ceiling (scope :: Symbol) amount = Ceiling amount
  deriving stock (Eq, Ord, Show)

-- | Zero forbids consumption. Absence of a ceiling is represented separately
-- by 'Maybe'; the underlying amount retains its original numeric range.
mkCeiling :: (Integral amount) => amount -> Either Text (Ceiling scope amount)
mkCeiling amount
  | amount < 0 = Left "policy ceiling must be nonnegative"
  | otherwise = Right (Ceiling amount)

ceilingValue :: Ceiling scope amount -> amount
ceilingValue (Ceiling amount) = amount

instance (ToJSON amount) => ToJSON (Ceiling scope amount) where
  toJSON = toJSON . ceilingValue
  toEncoding = toEncoding . ceilingValue

instance (Integral amount, FromJSON amount) => FromJSON (Ceiling scope amount) where
  parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . mkCeiling

type role Permission nominal

data Permission (scope :: Symbol) = Prohibited | Permitted
  deriving stock (Eq, Ord, Show)

permissionAllowed :: Permission scope -> Bool
permissionAllowed Prohibited = False
permissionAllowed Permitted = True

permissionFromBool :: Bool -> Permission scope
permissionFromBool False = Prohibited
permissionFromBool True = Permitted

instance ToJSON (Permission scope) where
  toJSON = toJSON . permissionAllowed
  toEncoding = toEncoding . permissionAllowed

instance FromJSON (Permission scope) where
  parseJSON = withBool "policy permission" (pure . permissionFromBool)

type role PolicyCoordinate nominal

newtype PolicyCoordinate (scope :: Symbol) = PolicyCoordinate Text
  deriving stock (Eq, Ord, Show)

-- | Exact policy-authored coordinate. Signing keys, algorithm names and provider
-- correlation fields have no local syntax contract; retaining a name does not
-- confer authority or select a signing implementation.
policyCoordinate :: Text -> PolicyCoordinate scope
policyCoordinate = PolicyCoordinate

policyCoordinateText :: PolicyCoordinate scope -> Text
policyCoordinateText (PolicyCoordinate value) = value

instance ToJSON (PolicyCoordinate scope) where
  toJSON = toJSON . policyCoordinateText
  toEncoding = toEncoding . policyCoordinateText

instance FromJSON (PolicyCoordinate scope) where
  parseJSON = withText "policy coordinate" (pure . policyCoordinate)
