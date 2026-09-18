-- | Complete compliance roll-up over one closed run-evidence set.
module Shikigami.Attestation.Compliance
  ( ComplianceRollUp (..),
    evaluateCompliance,
    finalizeCompliance,
  )
where

import Baikai.Cost qualified as Cost
import Baikai.Evidence qualified as Baikai
import Baikai.ThinkingLevel (renderThinkingLevel)
import Baikai.Usage qualified as Usage
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Shikigami.Attestation.Evidence
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Reviewed
  ( DiffDigest (..),
    NonConformingReason (..),
    ResultDigest (..),
    ReviewedArtifact (..),
  )
import Shikigami.Log.Correlation
  ( CallCorrelationId,
    RunCorrelationId,
    renderCallCorrelationId,
    renderRunCorrelationId,
  )
import Shikigami.Prelude

data ComplianceRollUp = ComplianceRollUp
  { sanctioned :: !Bool,
    reasons :: ![NonConformingReason],
    accountedCalls :: ![CallCorrelationId]
  }
  deriving stock (Eq, Show, Generic)

-- | Judge every call and every completeness obligation without short-circuiting.
-- 'NotApplicable' annotations remain in the result but do not make it
-- non-conforming.
evaluateCompliance :: Profile.SanctionedExecutionProfile -> RunEvidence -> ComplianceRollUp
evaluateCompliance sanctionedProfile runEvidence@RunEvidence {calls, deterministicSteps} =
  let allReasons =
        concatMap (callReasons sanctionedProfile calls) calls
          <> accountingReasons runEvidence
          <> artifactReasons runEvidence
          <> resultReasons runEvidence
          <> limitReasons sanctionedProfile runEvidence
          <> (NotApplicable <$> deterministicSteps)
   in ComplianceRollUp
        { sanctioned = all isAnnotation allReasons,
          reasons = allReasons,
          accountedCalls = [callId | RecordedCallEvidence {callId} <- calls]
        }

-- | Close child accounting, evaluate every rule, then choose the lifecycle
-- outcome atomically: sanctioned sets become evidence-sealed; any failure
-- reason becomes non-conforming.
finalizeCompliance ::
  Profile.SanctionedExecutionProfile ->
  BehaviorTerminalState ->
  [RelevantChild] ->
  RunEvidence ->
  Either SealRefusal (RunEvidence, ComplianceRollUp)
finalizeCompliance sanctionedProfile behavior relevantChildren runEvidence = do
  closed <- prepareEvidenceClosure runEvidence behavior relevantChildren
  let rollUp@ComplianceRollUp {sanctioned} = evaluateCompliance sanctionedProfile closed
      target = if sanctioned then EvidenceSealed else NonConforming
  finalized <-
    either
      (const (Left (EvidenceNotRunning Running)))
      Right
      (transitionEvidence closed target)
  pure (finalized, rollUp)

isAnnotation :: NonConformingReason -> Bool
isAnnotation NotApplicable {} = True
isAnnotation _ = False

callReasons ::
  Profile.SanctionedExecutionProfile ->
  [RecordedCallEvidence] ->
  RecordedCallEvidence ->
  [NonConformingReason]
callReasons
  Profile.SanctionedExecutionProfile
    { Profile.allowedCalls,
      Profile.prohibitions,
      Profile.minimumEvidenceStrength,
      Profile.requiredCorrelationFields
    }
  allCalls
  recorded@RecordedCallEvidence
    { callId,
      resolvedModelId,
      requestedAlias,
      evidence = terminal
    } =
    let renderedCallId = renderCallCorrelationId callId
        endpoint = terminal ^. #endpoint
        thinking = terminal ^. #thinking
        strength = terminal ^. #strength
        Baikai.EndpointIdentity {Baikai.provider, Baikai.api, Baikai.transport} = endpoint
        endpointClass = endpointClassOf endpoint
        permitted = toList allowedCalls
        modelReasons =
          [ ModelNotPermitted renderedCallId resolvedModelId
          | not (any (\allowed -> (.modelId) allowed == resolvedModelId) permitted)
          ]
        endpointReasons =
          [ ProhibitedEndpoint renderedCallId endpointClass
          | not (any (surfaceMatches provider api endpointClass) permitted)
          ]
        thinkingReasons = thinkingTranslationReasons renderedCallId provider api endpointClass resolvedModelId permitted prohibitions thinking
        aliasReasons =
          [ ProhibitedAlias renderedCallId alias resolvedModelId
          | Just alias <- [requestedAlias],
            not ((.aliasesAllowed) prohibitions)
          ]
        transportReasons =
          [ ProhibitedTransport renderedCallId (renderTransport transport)
          | transport == Baikai.TransportSubprocess,
            not ((.cliTransportsAllowed) prohibitions)
          ]
        fallbackReasons = relationshipReasons prohibitions allCalls recorded
        strengthReasons =
          [ EvidenceBelowRequiredStrength renderedCallId minimumEvidenceStrength strength
          | strength < minimumEvidenceStrength
          ]
        correlationReasons =
          [ MissingCorrelationField renderedCallId required
          | required <- requiredCorrelationFields,
            not (hasCorrelationField required terminal)
          ]
     in modelReasons
          <> endpointReasons
          <> thinkingReasons
          <> aliasReasons
          <> transportReasons
          <> fallbackReasons
          <> strengthReasons
          <> correlationReasons

surfaceMatches :: Text -> Text -> Text -> Profile.AllowedCall -> Bool
surfaceMatches provider api endpointClass Profile.AllowedCall {Profile.provider = allowedProvider, Profile.api = allowedApi, Profile.endpointClass = allowedEndpointClass} =
  provider == allowedProvider && api == allowedApi && endpointClass == allowedEndpointClass

thinkingTranslationReasons ::
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  [Profile.AllowedCall] ->
  Profile.Prohibitions ->
  Baikai.ThinkingTranslation ->
  [NonConformingReason]
thinkingTranslationReasons callId provider api endpointClass modelId permitted prohibitions translation@Baikai.ThinkingTranslation {Baikai.requested, Baikai.adjustments} =
  defaultReasons <> tupleReasons <> adjustmentReasons
  where
    defaultReasons =
      [ ProhibitedDefaultThinking callId
      | isNothing requested,
        not ((.defaultedThinkingAllowed) prohibitions)
      ]
    tupleReasons =
      [ ThinkingTranslationNotPermitted callId requestedText (effectiveThinkingText translation)
      | Just requestedLevel <- [requested],
        let requestedText = renderThinkingLevel requestedLevel,
        not
          ( any
              ( \allowed ->
                  surfaceMatches provider api endpointClass allowed
                    && (.modelId) allowed == modelId
                    && (.thinking) allowed == requestedLevel
              )
              permitted
          )
      ]
    adjustmentReasons =
      [ ProhibitedEffortClamping callId requestedText effective
      | adjustment <- adjustments,
        not ((.effortClampingAllowed) prohibitions),
        Just (requestedText, effective) <- [renderAdjustment adjustment]
      ]

renderAdjustment :: Baikai.ThinkingAdjustment -> Maybe (Text, Text)
renderAdjustment = \case
  Baikai.EffortClamped requested wire -> Just (renderThinkingLevel requested, wire)
  Baikai.EffortCollapsedToToggle requested -> Just (renderThinkingLevel requested, "toggle")
  Baikai.EffortOmitted requested -> Just (renderThinkingLevel requested, "omitted")
  Baikai.ThinkingDroppedUnsupportedModel requested -> Just (renderThinkingLevel requested, "unsupported-model")
  Baikai.ThinkingDroppedUnsupportedHost requested -> Just (renderThinkingLevel requested, "unsupported-host")
  Baikai.ThinkingDroppedBudgetExceeded requested _ _ -> Just (renderThinkingLevel requested, "budget-exceeded")
  Baikai.SamplingDroppedUnsupportedModel _ -> Nothing
  Baikai.SamplingDroppedUnsupportedApi _ -> Nothing

effectiveThinkingText :: Baikai.ThinkingTranslation -> Text
effectiveThinkingText Baikai.ThinkingTranslation {Baikai.effortText, Baikai.mode} =
  fromMaybe (renderThinkingMode mode) effortText

renderThinkingMode :: Baikai.ThinkingMode -> Text
renderThinkingMode = \case
  Baikai.ThinkingModeBudget -> "budget"
  Baikai.ThinkingModeAdaptive -> "adaptive"
  Baikai.ThinkingModeFlag -> "flag"
  Baikai.ThinkingModeToggle -> "toggle"
  Baikai.ThinkingModeUnsupported -> "unsupported"
  Baikai.ThinkingModeNotTranslated -> "not-translated"
  Baikai.ThinkingModeAbsent -> "absent"

relationshipReasons ::
  Profile.Prohibitions ->
  [RecordedCallEvidence] ->
  RecordedCallEvidence ->
  [NonConformingReason]
relationshipReasons prohibitions allCalls RecordedCallEvidence {callId, relationship, resolvedModelId, evidence = terminal} =
  case relationship of
    FallbackFrom previousCallId ->
      case find ((== previousCallId) . recordedCallId) allCalls of
        Nothing -> []
        Just RecordedCallEvidence {resolvedModelId = previousModel, evidence = previousTerminal} ->
          let currentProvider = evidenceProvider terminal
              previousProvider = evidenceProvider previousTerminal
              renderedCallId = renderCallCorrelationId callId
           in [ ProhibitedProviderFallback renderedCallId previousProvider currentProvider
              | previousProvider /= currentProvider,
                not ((.providerFallbackAllowed) prohibitions)
              ]
                <> [ ProhibitedModelFallback renderedCallId previousModel resolvedModelId
                   | previousModel /= resolvedModelId,
                     not ((.modelFallbackAllowed) prohibitions)
                   ]
    _ -> []

recordedCallId :: RecordedCallEvidence -> CallCorrelationId
recordedCallId RecordedCallEvidence {callId} = callId

evidenceProvider :: Baikai.ModelCallEvidence -> Text
evidenceProvider terminal = terminal ^. #endpoint . #provider

endpointClassOf :: Baikai.EndpointIdentity -> Text
endpointClassOf Baikai.EndpointIdentity {Baikai.transport, Baikai.endpoint} =
  case transport of
    Baikai.TransportHttpApi -> maybe "https" (Text.takeWhile (/= ':')) endpoint
    Baikai.TransportSubprocess -> "cli"
    Baikai.TransportAgentRun -> "in-process"

renderTransport :: Baikai.TransportKind -> Text
renderTransport = \case
  Baikai.TransportHttpApi -> "http_api"
  Baikai.TransportSubprocess -> "subprocess"
  Baikai.TransportAgentRun -> "agent_run"

hasCorrelationField :: Text -> Baikai.ModelCallEvidence -> Bool
hasCorrelationField requested terminal =
  case normalize requested of
    "responseid" -> isJust (Baikai.observedValue (terminal ^. #responseId))
    "providerrequestid" -> isJust (Baikai.observedValue (terminal ^. #providerRequestId))
    "clientrequestid" -> isJust (terminal ^. #clientRequestId)
    "callid" -> not (Text.null (baikaiCallId terminal))
    "runid" -> not (Text.null (baikaiRunId terminal))
    _ -> False
  where
    normalize = Text.toLower . Text.filter (`notElem` ['-', '_', '.'])

baikaiCallId :: Baikai.ModelCallEvidence -> Text
baikaiCallId terminal = terminal ^. #callId

baikaiRunId :: Baikai.ModelCallEvidence -> Text
baikaiRunId terminal = terminal ^. #runId

accountingReasons :: RunEvidence -> [NonConformingReason]
accountingReasons RunEvidence {expectedCalls, calls, expectedChildRunIds, delegatedChildren} =
  concatMap missingCall expectedCalls <> concatMap missingChild expectedChildRunIds
  where
    presentIds = [callId | RecordedCallEvidence {callId} <- calls]
    missingCall ExpectedCall {callId, relationship, attempt}
      | callId `elem` presentIds = []
      | otherwise =
          let rendered = renderCallCorrelationId callId
           in case relationship of
                RetryOf _ -> [MissingRetryEvidence rendered (fromIntegral attempt)]
                ContinuationOf _ -> [MissingContinuationEvidence rendered]
                _ -> [MissingCallEvidence rendered]
    missingChild expectedRunId =
      case find ((== expectedRunId) . relevantChildRunId) delegatedChildren of
        Nothing -> [MissingDelegatedChildEvidence (renderRunCorrelationId expectedRunId)]
        Just RelevantChild {calls = childCalls}
          | null childCalls -> [MissingDelegatedChildEvidence (renderRunCorrelationId expectedRunId)]
          | otherwise -> []

relevantChildRunId :: RelevantChild -> RunCorrelationId
relevantChildRunId RelevantChild {childRunId} = childRunId

artifactReasons :: RunEvidence -> [NonConformingReason]
artifactReasons RunEvidence {reviewed = ReviewedArtifact {diffDigest = DiffDigest expected}, observedArtifactDigest} =
  [ReviewedArtifactMismatch expected actual | Just (DiffDigest actual) <- [observedArtifactDigest], actual /= expected]

resultReasons :: RunEvidence -> [NonConformingReason]
resultReasons RunEvidence {resultEvidence} =
  case resultEvidence of
    Just ResultEvidence {expectedDigest = ResultDigest expected, actualDigest = ResultDigest actual}
      | expected /= actual -> [ReviewResultDigestMismatch expected actual]
    _ -> []

limitReasons :: Profile.SanctionedExecutionProfile -> RunEvidence -> [NonConformingReason]
limitReasons Profile.SanctionedExecutionProfile {Profile.limits} RunEvidence {calls, delegatedChildren, durationSeconds, peakConcurrency} =
  concat
    [ exceeded "maxCalls" ((.maxCalls) limits) (length calls),
      exceeded "maxRetries" ((.maxRetries) limits) (length [() | RecordedCallEvidence {relationship = RetryOf _} <- calls]),
      exceeded "maxDelegatedChildRuns" ((.maxDelegatedChildRuns) limits) (length delegatedChildren),
      exceeded "maxTokens" ((.maxTokens) limits) (totalTokens calls),
      exceededInteger "maxCostMicroUsd" ((.maxCostMicroUsd) limits) (costMicroUsd calls),
      maybe [] (\(RunDurationSeconds observed) -> exceeded "maxDurationSeconds" ((.maxDurationSeconds) limits) observed) durationSeconds,
      maybe [] (\(PeakConcurrency observed) -> exceeded "maxConcurrency" ((.maxConcurrency) limits) observed) peakConcurrency
    ]

exceeded :: (Integral quantity, Show quantity) => Text -> Maybe Int -> quantity -> [NonConformingReason]
exceeded name limit observed =
  [LimitExceeded name (showText maximumValue) (showText observed) | Just maximumValue <- [limit], toInteger observed > toInteger maximumValue]

exceededInteger :: Text -> Maybe Integer -> Rational -> [NonConformingReason]
exceededInteger name limit observed =
  [ LimitExceeded name (showText maximumValue) (showText observed)
  | Just maximumValue <- [limit],
    observed > fromInteger maximumValue
  ]

totalTokens :: [RecordedCallEvidence] -> Natural
totalTokens = sum . fmap terminalTokens

terminalTokens :: RecordedCallEvidence -> Natural
terminalTokens RecordedCallEvidence {evidence} =
  case evidence ^. #usage of
    Baikai.Observed observed -> Usage.totalTokens observed
    Baikai.Unobserved -> 0

costMicroUsd :: [RecordedCallEvidence] -> Rational
costMicroUsd = sum . fmap terminalCostMicroUsd

terminalCostMicroUsd :: RecordedCallEvidence -> Rational
terminalCostMicroUsd RecordedCallEvidence {evidence} =
  case evidence ^. #usage of
    Baikai.Observed observed -> Cost.usd (Usage.cost observed) * 1000000
    Baikai.Unobserved -> 0

showText :: (Show value) => value -> Text
showText = Text.pack . show
