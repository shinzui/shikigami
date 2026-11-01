{-# LANGUAGE DataKinds #-}

-- | Consumer-owned restartable facts. Baikai's full ModelCallEvidence remains
-- encode-only; no decoder for that producer-owned record is invented here.
module Shikigami.Attestation.CallFacts (CallComplianceFacts (..), callComplianceFacts, factsFromTerminal, RelationshipKnowledge (..), CostCertainty (..), MeasuredTokens, measuredTokens, measuredTokensNumber, MeasuredMicroUsd, measuredMicroUsd, measuredMicroUsdAmount, CorrelationField, correlationFieldText) where

import Baikai.Cost qualified as Cost
import Baikai.Evidence qualified as Baikai
import Baikai.Usage qualified as Usage
import Data.Aeson (FromJSON (..), ToJSON (..), defaultOptions, genericParseJSON, withText)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Shikigami.Attestation.Evidence (CallRelationship (..), ProviderAttempt, RecordedCallEvidence (..), providerAttempt)
import Shikigami.Behavior.Provider.Coordinate
import Shikigami.Decision.ModelAlias (ModelAlias)
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Log.Correlation (CallCorrelationId)

-- Keep exact requested/observed identities and translation quality distinct.
data CallComplianceFacts = CallComplianceFacts
  { format :: !(FormatVersion "call-compliance"),
    callId :: !CallCorrelationId,
    relationship :: !CallRelationship,
    relationshipKnown :: !RelationshipKnowledge,
    resolvedModelId :: !(ProviderCoordinate "provider-model-id"),
    requestedAlias :: !(Maybe ModelAlias),
    requestedModelId :: !(ProviderCoordinate "provider-model-id"),
    observedModelId :: !(Baikai.Observed (ProviderCoordinate "provider-model-id")),
    endpoint :: !Baikai.EndpointIdentity,
    thinking :: !Baikai.ThinkingTranslation,
    strength :: !Baikai.EvidenceStrength,
    status :: !Baikai.CallStatus,
    providerCallId :: !(ProviderCoordinate "provider-call-id"),
    providerRunId :: !(ProviderCoordinate "provider-run-id"),
    attempt :: !ProviderAttempt,
    correlationFields :: ![CorrelationField],
    tokens :: !(Maybe MeasuredTokens),
    costMicroUsd :: !(Maybe MeasuredMicroUsd),
    costUncertain :: !CostCertainty
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON CallComplianceFacts where
  parseJSON value = do
    facts <- genericParseJSON defaultOptions value
    if facts.format == V1 then pure facts else fail "unsupported call compliance facts version"

callComplianceFacts :: RecordedCallEvidence -> CallComplianceFacts
callComplianceFacts recorded = factsFromTerminal recorded.callId recorded.relationship recorded.resolvedModelId recorded.requestedAlias recorded.evidence

factsFromTerminal :: CallCorrelationId -> CallRelationship -> ProviderCoordinate "provider-model-id" -> Maybe ModelAlias -> Baikai.ModelCallEvidence -> CallComplianceFacts
factsFromTerminal callId relationship resolvedModelId requestedAlias terminal =
  CallComplianceFacts
    { format = V1,
      callId,
      relationship,
      relationshipKnown = RelationshipKnown,
      resolvedModelId,
      requestedAlias,
      requestedModelId = providerCoordinate terminal.requestedModel,
      observedModelId = providerCoordinate <$> terminal.observedModel,
      endpoint = terminal.endpoint,
      thinking = terminal.thinking,
      strength = terminal.strength,
      status = terminal.status,
      providerCallId = providerCoordinate terminal.callId,
      providerRunId = providerCoordinate terminal.runId,
      attempt = providerAttempt terminal.attempt,
      correlationFields =
        [ key
        | (key, present) <-
            [ (ResponseId, isJust (Baikai.observedValue terminal.responseId)),
              (ProviderRequestId, isJust (Baikai.observedValue terminal.providerRequestId)),
              (ClientRequestId, isJust terminal.clientRequestId),
              (ProviderCallId, not (nullText terminal.callId)),
              (ProviderRunId, not (nullText terminal.runId))
            ],
          present
        ],
      tokens = case Baikai.observedValue terminal.usage of
        Just usage | knownTokens usage -> Just (measuredTokens usage.totalTokens)
        _ -> Nothing,
      costMicroUsd = (\usage -> measuredMicroUsd (Cost.usd usage.cost * 1000000)) <$> Baikai.observedValue terminal.usage,
      costUncertain = if maybe True (\usage -> maybe True (not . Set.null . (\basis -> basis.estimateReasons)) (Cost.nonEmptyBasis usage.cost)) (Baikai.observedValue terminal.usage) then CostUncertain else CostKnown
    }
  where
    nullText = (== "")
    knownTokens usage = case usage.availability of
      Just quality -> Set.null quality.missingCategories && not quality.inconsistent
      Nothing -> usage.totalTokens > 0

newtype MeasuredTokens = MeasuredTokens Natural
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

measuredTokens :: Natural -> MeasuredTokens
measuredTokens = MeasuredTokens

measuredTokensNumber :: MeasuredTokens -> Natural
measuredTokensNumber (MeasuredTokens value) = value

-- Retain the provider's exact rational measurement, including its uncertainty.
newtype MeasuredMicroUsd = MeasuredMicroUsd Rational
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

measuredMicroUsd :: Rational -> MeasuredMicroUsd
measuredMicroUsd = MeasuredMicroUsd

measuredMicroUsdAmount :: MeasuredMicroUsd -> Rational
measuredMicroUsdAmount (MeasuredMicroUsd value) = value

data RelationshipKnowledge = RelationshipUnknown | RelationshipKnown
  deriving stock (Eq, Show)

instance ToJSON RelationshipKnowledge where
  toJSON value = toJSON (value == RelationshipKnown)
  toEncoding value = toEncoding (value == RelationshipKnown)

instance FromJSON RelationshipKnowledge where
  parseJSON value = (\known -> if known then RelationshipKnown else RelationshipUnknown) <$> parseJSON @Bool value

data CostCertainty = CostKnown | CostUncertain
  deriving stock (Eq, Show)

instance ToJSON CostCertainty where
  toJSON value = toJSON (value == CostUncertain)
  toEncoding value = toEncoding (value == CostUncertain)

instance FromJSON CostCertainty where
  parseJSON value = (\uncertain -> if uncertain then CostUncertain else CostKnown) <$> parseJSON @Bool value

data CorrelationField = ResponseId | ProviderRequestId | ClientRequestId | ProviderCallId | ProviderRunId
  deriving stock (Eq, Show)

correlationFieldText :: CorrelationField -> Text
correlationFieldText = \case
  ResponseId -> "responseid"
  ProviderRequestId -> "providerrequestid"
  ClientRequestId -> "clientrequestid"
  ProviderCallId -> "callid"
  ProviderRunId -> "runid"

instance ToJSON CorrelationField where
  toJSON = toJSON . correlationFieldText
  toEncoding = toEncoding . correlationFieldText

instance FromJSON CorrelationField where
  parseJSON = withText "provider correlation field" \case
    "responseid" -> pure ResponseId
    "providerrequestid" -> pure ProviderRequestId
    "clientrequestid" -> pure ClientRequestId
    "callid" -> pure ProviderCallId
    "runid" -> pure ProviderRunId
    _ -> fail "unknown provider correlation field"
