-- | The ingress side of an explicit practice-review resolution: authorize the
-- request, bind the receipt to it, and enqueue the envelope as an addressed
-- run for the OpenTelemetry reviewer.
module FlowPack.PracticeReview.ResolutionIntake
  ( enqueueAuthorizedPracticeReviewResolution,
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Text qualified as Text
import FlowPack.PracticeReview.Authorization
import FlowPack.PracticeReview.Types
  ( PracticeReviewResolutionRequest (..),
    validateResolutionRequest,
    validatedResolutionRequestValue,
  )
import Hasql.Pool (Pool)
import Pgmq (MessageId)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Agent.RunJob (RunRouteKind (AgentWorkflowRoute))
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Prelude hiding ((.=))
import Shikigami.Trigger.Enqueue (enqueueAddressedRunWithKey)
import Shikigami.Trigger.RequestKey qualified as Addressed

enqueueAuthorizedPracticeReviewResolution ::
  Pool ->
  AgentIdentity ->
  Text ->
  ReviewResolutionAuthorizer ->
  PracticeReviewResolutionRequest ->
  ResolutionSubmissionEvidence ->
  IO (Either ResolutionAuthorizationError MessageId)
enqueueAuthorizedPracticeReviewResolution pool identity agent ReviewResolutionAuthorizer {authorize} resolution submission
  | agent /= "opentelemetry-practice-reviewer" =
      pure (Left (ResolutionAuthorizerRefused "authorized practice-review resolutions may target only the OpenTelemetry reviewer"))
  | otherwise =
      case validateResolutionRequest resolution of
        Left errors -> pure (Left (ResolutionContractInvalid (Text.pack (show errors))))
        Right _ ->
          authorize resolution submission >>= \case
            Left refusal -> pure (Left refusal)
            Right receipt -> do
              let envelope =
                    AuthorizedPracticeReviewResolution
                      { schemaVersion = authorizationEnvelopeSchemaVersion,
                        resolution,
                        authorization = receipt
                      }
              -- The envelope validation is the receipt check: the request is
              -- already known valid, so only a subject or commitment mismatch
              -- can refuse here.
              case validateAuthorizedPracticeReviewResolution envelope of
                Left refusal -> pure (Left refusal)
                Right (validated, _) -> do
                  let PracticeReviewResolutionRequest {reviewId, idempotencyKey} = validatedResolutionRequestValue validated
                      key = versionedDigest "shikigami.practice-review-resolution-enqueue/2" (Aeson.object ["reviewId" .= reviewId, "key" .= idempotencyKey])
                  case (mkAgentName agent, Addressed.parseRequestKey key) of
                    (Left problem, _) -> pure (Left (ResolutionAuthorizerRefused problem))
                    (_, Left problem) -> pure (Left (ResolutionAuthorizerRefused problem))
                    (Right target, Right requestKey) ->
                      enqueueAddressedRunWithKey pool identity target AgentWorkflowRoute (Aeson.toJSON envelope) requestKey
                        <&> first (ResolutionEnqueueFailed . Text.pack . show)
