module Shikigami.Router.Declaration
  ( RouterDeclarationError (..),
    SelectionLimit,
    ValidatedRouterDeclaration (..),
    renderRouterDeclarationError,
    routerDeclarationErrors,
    selectionLimitInt,
    selectionLimitNatural,
    validateRouterDeclaration,
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Shikigami.Agent.Decl
  ( AgentDecl (..),
    ExpertiseDecl (..),
    RouterPolicy (..),
  )
import Shikigami.Prelude

-- | A router declaration is decoded before these semantic invariants are
-- checked, so every refusal can name the authoring mistake directly.
data RouterDeclarationError
  = EmptyExpertiseKey !Int
  | DuplicateExpertiseKey !Text
  | DuplicateDelegate !Text
  | RouterPolicyMissing
  | RouterHasNoDelegates
  | InvalidMaxSelections !Natural
  | MaxSelectionsExceedsDelegates !Natural !Natural
  deriving stock (Eq, Show)

-- | A positive, deliberately small fan-out bound. The constructor stays
-- private so downstream routing code cannot bypass declaration validation.
newtype SelectionLimit = SelectionLimit Natural
  deriving stock (Eq, Ord, Show)

data ValidatedRouterDeclaration = ValidatedRouterDeclaration
  { declaration :: !AgentDecl,
    policy :: !RouterPolicy,
    selectionLimit :: !SelectionLimit
  }
  deriving stock (Eq, Show, Generic)

selectionLimitNatural :: SelectionLimit -> Natural
selectionLimitNatural (SelectionLimit value) = value

-- | Total because declaration validation admits only values from 1 through 16.
selectionLimitInt :: SelectionLimit -> Int
selectionLimitInt = fromIntegral . selectionLimitNatural

-- | Validate the invariants common to specialist metadata and optional router
-- policy. An ordinary specialist may omit @routing@; if it is present, all
-- router-specific bounds are checked together so one CLI run reports every
-- mistake.
routerDeclarationErrors :: AgentDecl -> [RouterDeclarationError]
routerDeclarationErrors AgentDecl {expertise, delegates, routing} =
  expertiseErrors expertise
    <> (DuplicateDelegate <$> duplicatesInOrder delegates)
    <> case routing of
      Nothing -> []
      Just RouterPolicy {maxSelections} ->
        [RouterHasNoDelegates | null delegates]
          <> [InvalidMaxSelections maxSelections | maxSelections < 1 || maxSelections > 16]
          <> [ MaxSelectionsExceedsDelegates maxSelections distinctDelegateCount
             | maxSelections > distinctDelegateCount
             ]
  where
    distinctDelegateCount = fromIntegral (Set.size (Set.fromList delegates))

-- | Produce the domain value consumed by catalog construction. Unlike
-- 'routerDeclarationErrors', this entry point requires an actual router policy.
validateRouterDeclaration :: AgentDecl -> Either [RouterDeclarationError] ValidatedRouterDeclaration
validateRouterDeclaration declaration@AgentDecl {routing} =
  case (routing, routerDeclarationErrors declaration) of
    (Nothing, errors) -> Left (errors <> [RouterPolicyMissing])
    (Just _, errors@(_ : _)) -> Left errors
    (Just policy@RouterPolicy {maxSelections}, []) ->
      Right
        ValidatedRouterDeclaration
          { declaration,
            policy,
            selectionLimit = SelectionLimit maxSelections
          }

renderRouterDeclarationError :: RouterDeclarationError -> Text
renderRouterDeclarationError = \case
  EmptyExpertiseKey position ->
    "expertise key at position " <> tshow position <> " must not be empty"
  DuplicateExpertiseKey key ->
    "expertise key is duplicated after trimming and case-folding: " <> key
  DuplicateDelegate delegate ->
    "delegate name is duplicated: " <> delegate
  RouterPolicyMissing ->
    "router declaration requires routing policy"
  RouterHasNoDelegates ->
    "routing policy requires at least one declared delegate"
  InvalidMaxSelections value ->
    "maxSelections must be between 1 and 16 inclusive; got " <> tshow value
  MaxSelectionsExceedsDelegates maximumSelection delegateCount ->
    "maxSelections "
      <> tshow maximumSelection
      <> " exceeds the distinct delegate count "
      <> tshow delegateCount

expertiseErrors :: [ExpertiseDecl] -> [RouterDeclarationError]
expertiseErrors entries =
  [EmptyExpertiseKey position | (position, key) <- indexedKeys, Text.null key]
    <> (DuplicateExpertiseKey <$> duplicatesInOrder nonEmptyKeys)
  where
    indexedKeys = zip [1 ..] (normaliseExpertiseKey . keyOf <$> entries)
    nonEmptyKeys = [key | (_, key) <- indexedKeys, not (Text.null key)]
    keyOf ExpertiseDecl {key} = key

normaliseExpertiseKey :: Text -> Text
normaliseExpertiseKey = Text.toCaseFold . Text.strip

duplicatesInOrder :: (Ord a) => [a] -> [a]
duplicatesInOrder = go Set.empty Set.empty
  where
    go :: (Ord a) => Set a -> Set a -> [a] -> [a]
    go _ _ [] = []
    go seen reported (value : rest)
      | value `Set.member` reported = go seen reported rest
      | value `Set.member` seen = value : go seen (Set.insert value reported) rest
      | otherwise = go (Set.insert value seen) reported rest

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
