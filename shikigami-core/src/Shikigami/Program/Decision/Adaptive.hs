-- | One immutable generative slot. The model emits a closed proposal; the
-- checkpoint owner validates authority and commits executable operations later.
module Shikigami.Program.Decision.Adaptive (AdaptiveInput (..), AdaptiveResult (..), adaptiveProgram, decodeProposal) where

import Data.Aeson (FromJSON, ToJSON, Value (Null), eitherDecodeStrict')
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import GHC.Generics (Generic)
import Shikigami.Coordination.Proposal (Proposal)
import Shikigami.Decision.Contract
import Shikigami.Program.Decision
import Shikumi.Adapter (ToPrompt)
import Shikumi.Program (Program (Predict), emptyParams)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)

data AdaptiveInput = AdaptiveInput
  { coordinatorInstructions :: !Text,
    checkpointJson :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON, FromModel, ToSchema, Validatable, ToPrompt)

newtype AdaptiveResult = AdaptiveResult {proposalJson :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON, FromModel, ToSchema, Validatable, ToPrompt)

decodeProposal :: AdaptiveResult -> Either DecisionFailure Proposal
decodeProposal output = first (const (decisionFailure OutputDecodeFailure "adaptive output is not a closed proposal")) (eitherDecodeStrict' (encodeUtf8 output.proposalJson))

adaptiveProgram :: RegisteredProgram AdaptiveInput AdaptiveResult
adaptiveProgram =
  either (error . show) id $
    registerProgram
      "adaptive-delivery"
      "1"
      (versionedDigest "shikigami.adaptive-program-code/1" ("bounded-proposal-v1" :: Text))
      "adaptive-input/1"
      "adaptive-result/1"
      "adaptive-result-validator/1"
      "adaptive-derivation/1"
      Null
      (Predict (mkSignature "Choose a bounded next organization from the supplied authoritative checkpoint and pinned catalog. Return proposalJson containing exactly the closed Proposal JSON vocabulary supplied in checkpointJson. Copy its objective/revision/operation coordinates. Existing owners, roots and evidence references are authoritative. Choose small direct/one-worker work when sufficient; otherwise permitted local coordinators and descendants. Reflect only on meaningful findings, failures, critical-path changes or integration evidence. Rationale must name observed friction, expected benefit and later evidence. Await outstanding work when no adaptation is justified. Completion may only propose exact combined artifacts and verified checks. Never invent tool, path, credential or executable instructions.") emptyParams)
      jsonResultCodec
      (\input -> input <$ (bounded 16384 input.coordinatorInstructions >> bounded 262144 input.checkpointJson))
      (\result -> result <$ (bounded 65536 result.proposalJson >> first renderDecisionFailure (decodeProposal result)))
  where
    bounded limit value
      | Text.null (Text.strip value) || Text.length value > limit = Left "adaptive field is empty or exceeds its bound"
      | otherwise = Right ()
