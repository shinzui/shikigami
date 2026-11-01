{-# LANGUAGE DataKinds #-}

-- | Typed, strictly decoded routing decisions.
--
-- Model output is only a proposal.  A value becomes executable routing
-- authority only after 'validateRouteDecision' checks it against the exact
-- journaled catalog and the router's declared policy.
module Shikigami.Router.Decision
  ( RouteSelection (..),
    RouteOutcome (..),
    RouteDecision (..),
    RoutingError (..),
    ValidatedRouteDecision,
    validatedRouteDecision,
    validateRouteDecision,
    renderRoutingError,
  )
where

import Data.Aeson (Key, Value, object, withObject, withText, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Shikigami.Agent.Decl (ExpertiseDecl (..), RouterConfidence (..), RouterPolicy (..))
import Shikigami.Agent.ExpertiseKey (ExpertiseKey, expertiseKeyText)
import Shikigami.Agent.Name (AgentName, agentNameText)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Prelude hiding ((.=))
import Shikigami.Router.Catalog
  ( CandidateAvailability (..),
    CandidateCatalog (..),
    CandidateEntry (..),
    CatalogVersion,
    ExclusionReason,
  )
import Shikigami.Router.SelectionLimit (selectionLimitNatural)

-- | One specialist proposed by a route evaluator.
data RouteSelection = RouteSelection
  { agent :: !AgentName,
    expertise :: ![ExpertiseKey],
    confidence :: !RouterConfidence,
    rationale :: !Text
  }
  deriving stock (Eq, Show, Generic)

-- | Semantic outcomes are closed: only 'Matched' carries executable
-- selections, while 'NoMatch' and 'Ambiguous' deliberately spawn no child.
data RouteOutcome
  = Matched !(NonEmpty RouteSelection)
  | NoMatch !Text
  | Ambiguous !(NonEmpty RouteSelection) !Text
  deriving stock (Eq, Show, Generic)

-- | Versioned decision tied to one exact candidate catalog.
data RouteDecision = RouteDecision
  { version :: !(FormatVersion "route-decision"),
    catalogVersion :: !CatalogVersion,
    outcome :: !RouteOutcome
  }
  deriving stock (Eq, Show, Generic)

-- | Every independently actionable reason a proposal was refused.
data RoutingError
  = UnsupportedDecisionVersion !Natural
  | StaleCatalogVersion !CatalogVersion !CatalogVersion
  | DuplicateSelection !AgentName
  | UndeclaredSelection !AgentName
  | UnavailableSelection !AgentName !ExclusionReason
  | UnknownExpertise !AgentName !ExpertiseKey
  | ConfidenceBelowMinimum !AgentName !RouterConfidence !RouterConfidence
  | TooManySelections !Natural !Natural
  deriving stock (Eq, Show, Generic)

-- | Constructor intentionally hidden: validation is the only authority mint.
newtype ValidatedRouteDecision = ValidatedRouteDecision RouteDecision
  deriving stock (Eq, Show)

validatedRouteDecision :: ValidatedRouteDecision -> RouteDecision
validatedRouteDecision (ValidatedRouteDecision decision) = decision

instance ToJSON RouteSelection where
  toJSON RouteSelection {agent, expertise, confidence, rationale} =
    object
      [ "agent" .= agent,
        "expertise" .= expertise,
        "confidence" .= confidenceText confidence,
        "rationale" .= rationale
      ]

instance FromJSON RouteSelection where
  parseJSON = withObject "route selection" \fields -> do
    requireExactFields "route selection" ["agent", "expertise", "confidence", "rationale"] fields
    RouteSelection
      <$> fields .: "agent"
      <*> fields .: "expertise"
      <*> (fields .: "confidence" >>= parseConfidence)
      <*> fields .: "rationale"

instance ToJSON RouteDecision where
  toJSON RouteDecision {version, catalogVersion, outcome} =
    case outcome of
      Matched selections ->
        object
          [ "version" .= version,
            "catalogVersion" .= catalogVersion,
            "outcome" .= ("matched" :: Text),
            "selections" .= NonEmpty.toList selections
          ]
      NoMatch rationale ->
        object
          [ "version" .= version,
            "catalogVersion" .= catalogVersion,
            "outcome" .= ("no-match" :: Text),
            "rationale" .= rationale
          ]
      Ambiguous alternatives rationale ->
        object
          [ "version" .= version,
            "catalogVersion" .= catalogVersion,
            "outcome" .= ("ambiguous" :: Text),
            "alternatives" .= NonEmpty.toList alternatives,
            "rationale" .= rationale
          ]

instance FromJSON RouteDecision where
  parseJSON = withObject "route decision" \fields -> do
    decisionVersion <- fields .: "version"
    decisionCatalogVersion <- fields .: "catalogVersion"
    outcomeTag <- fields .: "outcome"
    parsedOutcome <- case outcomeTag :: Text of
      "matched" -> do
        requireExactFields "matched route decision" ["version", "catalogVersion", "outcome", "selections"] fields
        selectionValues <- fields .: "selections"
        Matched <$> parseNonEmpty "matched selections" selectionValues
      "no-match" -> do
        requireExactFields "no-match route decision" ["version", "catalogVersion", "outcome", "rationale"] fields
        NoMatch <$> fields .: "rationale"
      "ambiguous" -> do
        requireExactFields "ambiguous route decision" ["version", "catalogVersion", "outcome", "alternatives", "rationale"] fields
        Ambiguous
          <$> (parseNonEmpty "ambiguous alternatives" =<< fields .: "alternatives")
          <*> fields .: "rationale"
      other -> fail ("unknown route outcome: " <> Text.unpack other)
    pure
      RouteDecision
        { version = decisionVersion,
          catalogVersion = decisionCatalogVersion,
          outcome = parsedOutcome
        }

-- | Validate every proposal field, accumulating all independent refusals.
validateRouteDecision :: RouterPolicy -> CandidateCatalog -> RouteDecision -> Either (NonEmpty RoutingError) ValidatedRouteDecision
validateRouteDecision policy catalog decision =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right (ValidatedRouteDecision decision)
    Just refusals -> Left refusals
  where
    RouteDecision {catalogVersion = decisionCatalogVersion, outcome} = decision
    CandidateCatalog {version = expectedCatalogVersion, candidates} = catalog
    errors =
      [StaleCatalogVersion expectedCatalogVersion decisionCatalogVersion | decisionCatalogVersion /= expectedCatalogVersion]
        <> validateOutcome policy (Map.fromList [(name, candidate) | candidate@CandidateEntry {name} <- candidates]) outcome

validateOutcome :: RouterPolicy -> Map.Map AgentName CandidateEntry -> RouteOutcome -> [RoutingError]
validateOutcome policy catalogByName = \case
  Matched selections -> validateSelections policy catalogByName (NonEmpty.toList selections)
  NoMatch _ -> []
  Ambiguous alternatives _ -> validateSelections policy catalogByName (NonEmpty.toList alternatives)

validateSelections :: RouterPolicy -> Map.Map AgentName CandidateEntry -> [RouteSelection] -> [RoutingError]
validateSelections RouterPolicy {maxSelections, minimumConfidence} catalogByName selections =
  [ TooManySelections (fromIntegral (length selections)) (selectionLimitNatural maxSelections)
  | fromIntegral (length selections) > selectionLimitNatural maxSelections
  ]
    <> (DuplicateSelection <$> duplicatesInOrder [agent | RouteSelection {agent} <- selections])
    <> concatMap validateSelection selections
  where
    validateSelection RouteSelection {agent, expertise, confidence} =
      case Map.lookup agent catalogByName of
        Nothing -> [UndeclaredSelection agent]
        Just CandidateEntry {availability = Excluded reason} -> [UnavailableSelection agent reason]
        Just CandidateEntry {expertise = declaredExpertise, availability = Available} ->
          [ UnknownExpertise agent key
          | key <- expertise,
            key `Set.notMember` Set.fromList [declaredKey | ExpertiseDecl {key = declaredKey} <- declaredExpertise]
          ]
            <> [ ConfidenceBelowMinimum agent confidence minimumConfidence
               | confidence < minimumConfidence
               ]

renderRoutingError :: RoutingError -> Text
renderRoutingError = \case
  UnsupportedDecisionVersion decisionVersion ->
    "unsupported route decision version " <> tshow decisionVersion
  StaleCatalogVersion expected actual ->
    "route decision catalog version " <> tshow actual <> " does not match journaled catalog " <> tshow expected
  DuplicateSelection agent -> "route decision selects agent more than once: " <> agentNameText agent
  UndeclaredSelection agent -> "route decision names an undeclared candidate: " <> agentNameText agent
  UnavailableSelection agent reason ->
    "route decision names unavailable candidate " <> agentNameText agent <> ": " <> tshow reason
  UnknownExpertise agent key ->
    "route decision claims undeclared expertise " <> expertiseKeyText key <> " for " <> agentNameText agent
  ConfidenceBelowMinimum agent actual required ->
    "route decision confidence for " <> agentNameText agent <> " is " <> confidenceText actual <> "; minimum is " <> confidenceText required
  TooManySelections actual selectionMaximum ->
    "route decision selects " <> tshow actual <> " candidates; maximum is " <> tshow selectionMaximum

parseConfidence :: Value -> Parser RouterConfidence
parseConfidence = withText "route confidence" \case
  "low" -> pure RoutingLow
  "medium" -> pure RoutingMedium
  "high" -> pure RoutingHigh
  other -> fail ("unknown route confidence: " <> Text.unpack other)

confidenceText :: RouterConfidence -> Text
confidenceText = \case
  RoutingLow -> "low"
  RoutingMedium -> "medium"
  RoutingHigh -> "high"

parseNonEmpty :: (FromJSON a) => String -> [Value] -> Parser (NonEmpty a)
parseNonEmpty label values = do
  parsed <- traverse parseJSON values
  maybe (fail (label <> " must not be empty")) pure (NonEmpty.nonEmpty parsed)

requireExactFields :: String -> [Key] -> Aeson.Object -> Parser ()
requireExactFields label expected fields =
  unless (actual == wanted) do
    fail
      ( label
          <> " must contain exactly fields "
          <> show (Set.toAscList wanted)
          <> "; got "
          <> show (Set.toAscList actual)
      )
  where
    actual = Set.fromList (KeyMap.keys fields)
    wanted = Set.fromList expected

duplicatesInOrder :: (Ord a) => [a] -> [a]
duplicatesInOrder = go Set.empty Set.empty
  where
    go _ _ [] = []
    go seen reported (value : rest)
      | value `Set.member` reported = go seen reported rest
      | value `Set.member` seen = value : go seen (Set.insert value reported) rest
      | otherwise = go (Set.insert value seen) reported rest

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
