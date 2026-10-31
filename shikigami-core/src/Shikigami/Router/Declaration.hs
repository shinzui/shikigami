module Shikigami.Router.Declaration
  ( RouterDeclarationError (..),
    SelectionLimit,
    ValidatedRouterDeclaration,
    RouterDeclarationView (..),
    validatedRouterDeclaration,
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
import Shikigami.Agent.ExpertiseKey (ExpertiseKey, duplicateExpertiseKeys, expertiseKeyText)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.Prelude
import Shikigami.Router.SelectionLimit (SelectionLimit, selectionLimitInt, selectionLimitNatural)

-- | A router declaration is decoded before these semantic invariants are
-- checked, so every refusal can name the authoring mistake directly.
data RouterDeclarationError
  = DuplicateExpertiseKey !ExpertiseKey
  | DuplicateDelegate !AgentName
  | RouterPolicyMissing
  | RouterHasNoDelegates
  | MaxSelectionsExceedsDelegates !Natural !Natural
  deriving stock (Eq, Show)

newtype ValidatedRouterDeclaration = ValidatedRouterDeclaration RouterDeclarationView
  deriving stock (Eq, Show)

validatedRouterDeclaration :: ValidatedRouterDeclaration -> RouterDeclarationView
validatedRouterDeclaration (ValidatedRouterDeclaration view) = view

data RouterDeclarationView = RouterDeclarationView
  { declaration :: !AgentDecl,
    policy :: !RouterPolicy,
    selectionLimit :: !SelectionLimit
  }
  deriving stock (Eq, Show, Generic)

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
          <> [ MaxSelectionsExceedsDelegates (selectionLimitNatural maxSelections) distinctDelegateCount
             | selectionLimitNatural maxSelections > distinctDelegateCount
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
      Right (ValidatedRouterDeclaration (RouterDeclarationView declaration policy maxSelections))

renderRouterDeclarationError :: RouterDeclarationError -> Text
renderRouterDeclarationError = \case
  DuplicateExpertiseKey key ->
    "expertise key is duplicated after trimming and case-folding: " <> expertiseKeyText key
  DuplicateDelegate delegate ->
    "delegate name is duplicated: " <> agentNameText delegate
  RouterPolicyMissing ->
    "router declaration requires routing policy"
  RouterHasNoDelegates ->
    "routing policy requires at least one declared delegate"
  MaxSelectionsExceedsDelegates maximumSelection delegateCount ->
    "maxSelections "
      <> tshow maximumSelection
      <> " exceeds the distinct delegate count "
      <> tshow delegateCount

expertiseErrors :: [ExpertiseDecl] -> [RouterDeclarationError]
expertiseErrors entries = DuplicateExpertiseKey <$> duplicateExpertiseKeys [key | ExpertiseDecl {key} <- entries]

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
