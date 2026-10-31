{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RoleAnnotations #-}

-- | Nonnegative revisions with distinct, nominal scopes. Wire adapters unwrap
-- explicitly; arithmetic does not make unrelated revision domains interchangeable.
module Shikigami.StateRevision
  ( StateRevision,
    parseRevision,
    revisionNumber,
    initialRevision,
    advanceRevision,
    advanceRevisions,
    previousRevision,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.TypeLits (Symbol)

type role StateRevision nominal

newtype StateRevision (scope :: Symbol) = StateRevision Integer
  deriving stock (Eq, Ord, Show)

parseRevision :: Integer -> Either Text (StateRevision scope)
parseRevision number
  | number >= 0 = Right (StateRevision number)
  | otherwise = Left "revision must be nonnegative"

revisionNumber :: StateRevision scope -> Integer
revisionNumber (StateRevision number) = number

initialRevision :: StateRevision scope
initialRevision = StateRevision 0

advanceRevision :: StateRevision scope -> StateRevision scope
advanceRevision (StateRevision number) = StateRevision (number + 1)

-- | Advance a nonnegative number of revisions without losing the scope.
advanceRevisions :: Word -> StateRevision scope -> StateRevision scope
advanceRevisions count (StateRevision number) = StateRevision (number + toInteger count)

-- | A predecessor is absent at the initial revision; never admit a negative value.
previousRevision :: StateRevision scope -> Maybe (StateRevision scope)
previousRevision (StateRevision number)
  | number == 0 = Nothing
  | otherwise = Just (StateRevision (number - 1))

instance ToJSON (StateRevision scope) where
  toJSON = toJSON . revisionNumber
  toEncoding = toEncoding . revisionNumber

instance FromJSON (StateRevision scope) where
  parseJSON value = do
    number <- parseJSON value
    either (fail . Text.unpack) pure (parseRevision number)
