-- | Key-free decision fixtures use the real Shikumi dispatch path. The
-- honest evidence strength is requested-only: no remote model serves this API.
module Shikigami.Decision.StubProvider (decisionStubProvider) where

import Baikai.Content (AssistantContent (AssistantText), TextContent (..))
import Baikai.Evidence qualified as Evidence
import Baikai.Model qualified as Model
import Baikai.Options qualified as Options
import Baikai.Provider.Registry (ApiProvider (..))
import Baikai.Response (emptyResponse)
import Baikai.Stream (liftCompleteToStream)
import Data.Aeson (Value, encode, object, toJSON, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Data.Vector qualified as V
import Shikigami.Behavior.StubProvider (stubApiProvider)
import Shikigami.Prelude ((&), (.~))

decisionStubProvider :: ApiProvider
decisionStubProvider = (stubApiProvider & #complete .~ (complete) & #stream .~ (liftCompleteToStream complete))
  where
    complete model context options = do
      now <- getCurrentTime
      callId <- Evidence.newCallId
      let reply
            | Model.modelId model == "stub-propose" = stubAssessment (Text.pack (show context))
            | Model.modelId model == "stub-triage" = object ["action" .= ("Investigate" :: Text), "summary" .= ("Stub triage requests investigation" :: Text), "confidence" .= (1 :: Double)]
            | otherwise = object ["action" .= ("ReturnResult" :: Text), "summary" .= ("Stub investigation completed" :: Text), "routeJson" .= ("" :: Text), "confidence" .= (1 :: Double)]
          request = object ["model" .= model, "context" .= Text.pack (show context), "options" .= options]
          response = emptyResponse & #message . #content .~ V.singleton (AssistantText (TextContent (TE.decodeUtf8 (LBS.toStrict (encode reply)))))
          evidence =
            ( \requested ->
                Evidence.baseEvidence
                  requested
                  callId
                  (Evidence.EndpointIdentity "stub" "stub" Evidence.TransportAgentRun Nothing "0.7.2.0" (Just "shikigami-decision-stub/1"))
                  (Model.modelId model)
                  Evidence.noThinkingRequested
                  now
                  now
                  Evidence.CallSucceeded
                  (Evidence.commitmentDigest request)
                  (Evidence.configurationDigest request)
                  & #responseCommitment
                  .~ Evidence.Observed (Evidence.commitmentDigest reply)
            )
              <$> options.evidence
      pure (response & #evidence .~ evidence)

-- | Scripted assessments. A fixture steers one with a marker in its excerpt, so
-- a test can exercise every answer the validator must refuse through the real
-- dispatch path. The unmarked answer is well formed.
stubAssessment :: Text -> Value
stubAssessment prompt
  | marked "stub:not-actionable" = assessment False Nothing Nothing []
  | marked "stub:repository-out-of-range" = assessment True (Just 7) (Just "reproduce-and-diagnose") [0]
  | marked "stub:forbidden-action" = assessment True (Just 0) (Just "merge-and-deploy") [0]
  | marked "stub:unknown-evidence" = assessment True (Just 0) (Just "reproduce-and-diagnose") [9]
  | otherwise = assessment True (Just 0) (Just "reproduce-and-diagnose") [0]
  where
    marked = (`Text.isInfixOf` prompt)
    assessment :: Bool -> Maybe Int -> Maybe Text -> [Int] -> Value
    assessment actionable repository action cited =
      object
        [ "actionable" .= actionable,
          "outcome" .= ("Checkout charges a card once per order" :: Text),
          "criteria" .= (["A double click produces one charge" :: Text]),
          "repositoryIndex" .= repository,
          "actionClass" .= action,
          "confidence" .= (0.9 :: Double),
          "evidenceIndexes" .= cited,
          "rationale" .= ("The message describes a reproducible defect" :: Text)
        ]
