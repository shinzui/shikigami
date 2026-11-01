{-# LANGUAGE DataKinds #-}

-- | Complete compliance roll-up over one closed run-evidence set.
module Shikigami.Attestation.Compliance
  ( ComplianceRollUp (..),
    evaluateCompliance,
    evaluateComplianceFacts,
    evaluateCallFacts,
    finalizeCompliance,
    finalizeComplianceFacts,
  )
where

import Baikai.Evidence qualified as Baikai
import Baikai.ThinkingLevel (renderThinkingLevel)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Text qualified as Text
import Shikigami.Attestation.CallFacts
import Shikigami.Attestation.Evidence
import Shikigami.Attestation.PolicyValue
import Shikigami.Attestation.Profile qualified as Profile
import Shikigami.Attestation.Reviewed
  ( DiffDigest (..),
    NonConformingReason (..),
    ResultDigest (..),
    ReviewedArtifact (..),
  )
import Shikigami.Behavior.Provider.Coordinate
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
  deriving anyclass (ToJSON, FromJSON)

-- | Judge every call and every completeness obligation without short-circuiting.
-- 'NotApplicable' annotations remain in the result but do not make it
-- non-conforming.
evaluateCompliance :: Profile.SanctionedExecutionProfile -> RunEvidence -> ComplianceRollUp
evaluateCompliance sanctionedProfile runEvidence =
  evaluateComplianceFacts sanctionedProfile runEvidence (callComplianceFacts <$> runEvidence.calls)

-- | Static artifact/result/child context still belongs to RunEvidence. The call
-- evaluator consumes the same facts for a live collector and a restarted store.
evaluateComplianceFacts :: Profile.SanctionedExecutionProfile -> RunEvidence -> [CallComplianceFacts] -> ComplianceRollUp
evaluateComplianceFacts sanctionedProfile runEvidence facts =
  let callReport = evaluateCallFacts sanctionedProfile runEvidence.expectedCalls facts
      allReasons =
        callReport.reasons
          <> childAccountingReasons runEvidence
          <> artifactReasons runEvidence
          <> resultReasons runEvidence
          <> limitReasons sanctionedProfile runEvidence facts
          <> (NotApplicable <$> runEvidence.deterministicSteps)
   in ComplianceRollUp (all isAnnotation allReasons) allReasons callReport.accountedCalls

evaluateCallFacts :: Profile.SanctionedExecutionProfile -> [ExpectedCall] -> [CallComplianceFacts] -> ComplianceRollUp
evaluateCallFacts sanctionedProfile expected facts =
  let ids = map (\fact -> fact.callId) facts
      missing = [missingReason call | call <- expected, call.callId `notElem` ids]
      missingReason ExpectedCall {callId, relationship, attempt} = case relationship of
        RetryOf _ -> MissingRetryEvidence (renderCallCorrelationId callId) (fromIntegral attempt)
        ContinuationOf _ -> MissingContinuationEvidence (renderCallCorrelationId callId)
        _ -> MissingCallEvidence (renderCallCorrelationId callId)
      reasons = concatMap (callReasons sanctionedProfile facts) facts <> missing <> callLimitReasons sanctionedProfile facts
   in ComplianceRollUp (all isAnnotation reasons) reasons ids

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

-- | The same lifecycle and artifact/result/child guards when parent calls are
-- restored as facts. Child records supplied by the closure retain their IDs;
-- merge by identity so a terminal already folded into the parent is not counted
-- twice.
finalizeComplianceFacts :: Profile.SanctionedExecutionProfile -> BehaviorTerminalState -> [RelevantChild] -> RunEvidence -> [CallComplianceFacts] -> Either SealRefusal (RunEvidence, ComplianceRollUp)
finalizeComplianceFacts profile behavior children evidence facts = do
  closed <- prepareEvidenceClosure evidence behavior children
  let combined = foldl' (\seen fact -> if any (\old -> old.callId == fact.callId) seen then seen else seen <> [fact]) facts (callComplianceFacts <$> closed.calls)
      rollUp = evaluateComplianceFacts profile closed combined
      target = if rollUp.sanctioned then EvidenceSealed else NonConforming
  finalized <- either (const (Left (EvidenceNotRunning Running))) Right (transitionEvidence closed target)
  pure (finalized, rollUp)

isAnnotation :: NonConformingReason -> Bool
isAnnotation NotApplicable {} = True
isAnnotation _ = False

callReasons ::
  Profile.SanctionedExecutionProfile ->
  [CallComplianceFacts] ->
  CallComplianceFacts ->
  [NonConformingReason]
callReasons
  Profile.SanctionedExecutionProfile
    { Profile.allowedCalls,
      Profile.prohibitions,
      Profile.minimumEvidenceStrength,
      Profile.requiredCorrelationFields
    }
  allCalls
  recorded@CallComplianceFacts
    { callId,
      resolvedModelId,
      requestedAlias
    } =
    let renderedCallId = renderCallCorrelationId callId
        endpoint = recorded.endpoint
        thinking = recorded.thinking
        strength = recorded.strength
        Baikai.EndpointIdentity {Baikai.provider = rawProvider, Baikai.api = rawApi, Baikai.transport} = endpoint
        provider = providerCoordinate rawProvider
        api = providerCoordinate rawApi
        endpointClass = providerCoordinate (endpointClassOf endpoint)
        resolvedCoordinate = providerCoordinate resolvedModelId
        permitted = toList allowedCalls
        modelReasons =
          [ ModelNotPermitted renderedCallId resolvedModelId
          | not (any (\allowed -> (.modelId) allowed == resolvedCoordinate) permitted)
          ]
        endpointReasons =
          [ ProhibitedEndpoint renderedCallId (providerCoordinateText endpointClass)
          | not (any (surfaceMatches provider api endpointClass) permitted)
          ]
        thinkingReasons = thinkingTranslationReasons renderedCallId provider api endpointClass resolvedCoordinate permitted prohibitions thinking
        aliasReasons =
          [ ProhibitedAlias renderedCallId alias resolvedModelId
          | Just alias <- [requestedAlias],
            not (permissionAllowed ((.aliasesAllowed) prohibitions))
          ]
        transportReasons =
          [ ProhibitedTransport renderedCallId (renderTransport transport)
          | transport == Baikai.TransportSubprocess,
            not (permissionAllowed ((.cliTransportsAllowed) prohibitions))
          ]
        fallbackReasons = relationshipReasons prohibitions allCalls recorded
        strengthReasons =
          [ EvidenceBelowRequiredStrength renderedCallId minimumEvidenceStrength strength
          | strength < minimumEvidenceStrength
          ]
        correlationReasons =
          [ MissingCorrelationField renderedCallId (policyCoordinateText required)
          | required <- requiredCorrelationFields,
            not (hasCorrelationField (policyCoordinateText required) recorded)
          ]
     in modelReasons
          <> endpointReasons
          <> thinkingReasons
          <> aliasReasons
          <> transportReasons
          <> fallbackReasons
          <> strengthReasons
          <> correlationReasons

surfaceMatches :: ProviderCoordinate "provider-name" -> ProviderCoordinate "provider-api" -> ProviderCoordinate "endpoint-class" -> Profile.AllowedCall -> Bool
surfaceMatches provider api endpointClass Profile.AllowedCall {Profile.provider = allowedProvider, Profile.api = allowedApi, Profile.endpointClass = allowedEndpointClass} =
  provider == allowedProvider && api == allowedApi && endpointClass == allowedEndpointClass

thinkingTranslationReasons ::
  Text ->
  ProviderCoordinate "provider-name" ->
  ProviderCoordinate "provider-api" ->
  ProviderCoordinate "endpoint-class" ->
  ProviderCoordinate "provider-model-id" ->
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
        not (permissionAllowed ((.defaultedThinkingAllowed) prohibitions))
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
        not (permissionAllowed ((.effortClampingAllowed) prohibitions)),
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
  Baikai.FastModeDroppedUnsupportedModel -> Nothing
  Baikai.ThinkingSummaryUnavailable -> Nothing

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
  [CallComplianceFacts] ->
  CallComplianceFacts ->
  [NonConformingReason]
relationshipReasons prohibitions allCalls current@CallComplianceFacts {callId, relationship, resolvedModelId} =
  case relationship of
    FallbackFrom previousCallId ->
      case find ((== previousCallId) . recordedCallId) allCalls of
        Nothing -> []
        Just previous@CallComplianceFacts {resolvedModelId = previousModel} ->
          let currentProvider = current.endpoint.provider
              previousProvider = previous.endpoint.provider
              renderedCallId = renderCallCorrelationId callId
           in [ ProhibitedProviderFallback renderedCallId previousProvider currentProvider
              | previousProvider /= currentProvider,
                not (permissionAllowed ((.providerFallbackAllowed) prohibitions))
              ]
                <> [ ProhibitedModelFallback renderedCallId previousModel resolvedModelId
                   | previousModel /= resolvedModelId,
                     not (permissionAllowed ((.modelFallbackAllowed) prohibitions))
                   ]
    _ -> []

recordedCallId :: CallComplianceFacts -> CallCorrelationId
recordedCallId fact = fact.callId

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

hasCorrelationField :: Text -> CallComplianceFacts -> Bool
hasCorrelationField requested facts =
  Text.toLower (Text.filter (`notElem` ['-', '_', '.']) requested) `elem` facts.correlationFields

childAccountingReasons :: RunEvidence -> [NonConformingReason]
childAccountingReasons RunEvidence {expectedChildRunIds, delegatedChildren} = concatMap missingChild expectedChildRunIds
  where
    missingChild expectedRunId = case find ((== expectedRunId) . relevantChildRunId) delegatedChildren of
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

callLimitReasons :: Profile.SanctionedExecutionProfile -> [CallComplianceFacts] -> [NonConformingReason]
callLimitReasons Profile.SanctionedExecutionProfile {Profile.limits} calls =
  concat
    [ [UnknownCallUsage (renderCallCorrelationId fact.callId) "retry-relationship" | isJust limits.maxRetries, fact <- calls, not fact.relationshipKnown],
      exceeded "maxCalls" limits.maxCalls (length calls),
      exceeded "maxRetries" limits.maxRetries (length [() | CallComplianceFacts {relationship = RetryOf _} <- calls]),
      exceeded "maxTokens" limits.maxTokens (sum [tokens | CallComplianceFacts {tokens = Just tokens} <- calls]),
      exceededInteger "maxCostMicroUsd" limits.maxCostMicroUsd (sum [cost | CallComplianceFacts {costMicroUsd = Just cost} <- calls]),
      [UnknownCallUsage (renderCallCorrelationId fact.callId) "tokens" | isJust limits.maxTokens, fact <- calls, isNothing fact.tokens],
      [UnknownCallUsage (renderCallCorrelationId fact.callId) "cost" | isJust limits.maxCostMicroUsd, fact <- calls, fact.costUncertain || isNothing fact.costMicroUsd]
    ]

limitReasons :: Profile.SanctionedExecutionProfile -> RunEvidence -> [CallComplianceFacts] -> [NonConformingReason]
limitReasons Profile.SanctionedExecutionProfile {Profile.limits} RunEvidence {delegatedChildren, durationSeconds, peakConcurrency} _ =
  concat
    [ exceeded "maxDelegatedChildRuns" limits.maxDelegatedChildRuns (length delegatedChildren),
      maybe [] (\(RunDurationSeconds observed) -> exceeded "maxDurationSeconds" limits.maxDurationSeconds observed) durationSeconds,
      maybe [] (\(PeakConcurrency observed) -> exceeded "maxConcurrency" limits.maxConcurrency observed) peakConcurrency
    ]

exceeded :: (Integral quantity, Show quantity) => Text -> Maybe (Ceiling scope Int) -> quantity -> [NonConformingReason]
exceeded name limit observed =
  [LimitExceeded name (showText maximumValue) (showText observed) | Just maximumValue <- [ceilingValue <$> limit], toInteger observed > toInteger maximumValue]

exceededInteger :: Text -> Maybe (Ceiling scope Integer) -> Rational -> [NonConformingReason]
exceededInteger name limit observed =
  [ LimitExceeded name (showText maximumValue) (showText observed)
  | Just maximumValue <- [ceilingValue <$> limit],
    observed > fromInteger maximumValue
  ]

showText :: (Show value) => value -> Text
showText = Text.pack . show
