{-# LANGUAGE DataKinds #-}

-- | Consumer-owned restartable facts. Baikai's full ModelCallEvidence remains
-- encode-only; no decoder for that producer-owned record is invented here.
module Shikigami.Attestation.CallFacts (CallComplianceFacts (..), callComplianceFacts, factsFromTerminal) where

import Baikai.Cost qualified as Cost
import Baikai.Evidence qualified as Baikai
import Baikai.Usage qualified as Usage
import Data.Aeson (FromJSON (..), ToJSON, defaultOptions, genericParseJSON)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Shikigami.Attestation.Evidence (CallRelationship (..), RecordedCallEvidence (..))
import Shikigami.FormatVersion (FormatVersion (V1))
import Shikigami.Log.Correlation (CallCorrelationId)

-- Keep exact requested/observed identities and translation quality distinct.
data CallComplianceFacts = CallComplianceFacts
  { format :: !(FormatVersion "call-compliance"),
    callId :: !CallCorrelationId,
    relationship :: !CallRelationship,
    relationshipKnown :: !Bool,
    resolvedModelId :: !Text,
    requestedAlias :: !(Maybe Text),
    requestedModelId :: !Text,
    observedModelId :: !(Baikai.Observed Text),
    endpoint :: !Baikai.EndpointIdentity,
    thinking :: !Baikai.ThinkingTranslation,
    strength :: !Baikai.EvidenceStrength,
    status :: !Baikai.CallStatus,
    providerCallId :: !Text,
    providerRunId :: !Text,
    attempt :: !Natural,
    correlationFields :: ![Text],
    tokens :: !(Maybe Natural),
    costMicroUsd :: !(Maybe Rational),
    costUncertain :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON CallComplianceFacts where
  parseJSON value = do
    facts <- genericParseJSON defaultOptions value
    if facts.format == V1 then pure facts else fail "unsupported call compliance facts version"

callComplianceFacts :: RecordedCallEvidence -> CallComplianceFacts
callComplianceFacts recorded = factsFromTerminal recorded.callId recorded.relationship recorded.resolvedModelId recorded.requestedAlias recorded.evidence

factsFromTerminal :: CallCorrelationId -> CallRelationship -> Text -> Maybe Text -> Baikai.ModelCallEvidence -> CallComplianceFacts
factsFromTerminal callId relationship resolvedModelId requestedAlias terminal =
  CallComplianceFacts
    { format = V1,
      callId,
      relationship,
      relationshipKnown = True,
      resolvedModelId,
      requestedAlias,
      requestedModelId = terminal.requestedModel,
      observedModelId = terminal.observedModel,
      endpoint = terminal.endpoint,
      thinking = terminal.thinking,
      strength = terminal.strength,
      status = terminal.status,
      providerCallId = terminal.callId,
      providerRunId = terminal.runId,
      attempt = terminal.attempt,
      correlationFields =
        [ key
        | (key, present) <-
            [ ("responseid", isJust (Baikai.observedValue terminal.responseId)),
              ("providerrequestid", isJust (Baikai.observedValue terminal.providerRequestId)),
              ("clientrequestid", isJust terminal.clientRequestId),
              ("callid", not (nullText terminal.callId)),
              ("runid", not (nullText terminal.runId))
            ],
          present
        ],
      tokens = case Baikai.observedValue terminal.usage of
        Just usage | knownTokens usage -> Just usage.totalTokens
        _ -> Nothing,
      costMicroUsd = (\usage -> Cost.usd usage.cost * 1000000) <$> Baikai.observedValue terminal.usage,
      costUncertain = maybe True (\usage -> maybe True (not . Set.null . (\basis -> basis.estimateReasons)) (Cost.nonEmptyBasis usage.cost)) (Baikai.observedValue terminal.usage)
    }
  where
    nullText = (== "")
    knownTokens usage = case usage.availability of
      Just quality -> Set.null quality.missingCategories && not quality.inconsistent
      Nothing -> usage.totalTokens > 0
