module Shikigami.Program.Decision.Examples
  ( Request (..),
    TriageAction (..),
    TriageResult (..),
    InvestigationInput (..),
    InvestigationAction (..),
    InvestigationResult (..),
    triageProgram,
    investigationProgram,
    examplePrograms,
    exampleCodecs,
  )
where

import Data.Aeson (FromJSON, ToJSON, Value (Null))
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.Program.Decision
import Shikumi.Adapter (ToPrompt)
import Shikumi.Program (Program (..), emptyParams)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (mkSignature)

data Request = Request {request :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromModel, ToSchema, Validatable, ToPrompt)

data TriageAction = ReturnNow | Investigate
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromModel, ToSchema)

data TriageResult = TriageResult {action :: !TriageAction, summary :: !Text, confidence :: !Double}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromModel, ToSchema, Validatable, ToPrompt)

data InvestigationInput = InvestigationInput {request :: !Text, triageSummary :: !Text, candidateCatalog :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromModel, ToSchema, Validatable, ToPrompt)

data InvestigationAction = ReturnResult | ProposeRoute
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromModel, ToSchema)

data InvestigationResult = InvestigationResult {action :: !InvestigationAction, summary :: !Text, routeJson :: !Text, confidence :: !Double}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON, FromModel, ToSchema, Validatable, ToPrompt)

triageProgram :: RegisteredProgram Request TriageResult
triageProgram =
  mustRegister $
    registerProgram
      "request-triage"
      "1"
      (versionedDigest "shikigami.triage-code/1" ("triage-v1" :: Text))
      "request/1"
      "triage-result/1"
      "triage-validator/1"
      "triage-derivation/1"
      Null
      (Predict (mkSignature "Triage the request. ReturnNow if it can be answered immediately; otherwise Investigate. Return a bounded summary and confidence between zero and one.") emptyParams)
      jsonResultCodec
      (\input -> input <$ bounded 4096 input.request)
      (\result -> result <$ (bounded 2048 result.summary >> confidenceValid result.confidence))

investigationProgram :: RegisteredProgram InvestigationInput InvestigationResult
investigationProgram =
  mustRegister $
    registerProgram
      "request-investigation"
      "1"
      (versionedDigest "shikigami.investigation-code/1" ("investigation-v1" :: Text))
      "investigation-input/1"
      "investigation-result/1"
      "investigation-validator/1"
      "investigation-derivation/1"
      Null
      ( Compose
          (Predict (mkSignature @InvestigationInput @InvestigationResult "Investigate the original request using the triage and bounded candidate catalog. Propose ReturnResult (empty routeJson) or ProposeRoute with strict JSON in routeJson. Route JSON has version=1, catalogVersion copied from the supplied catalog version, and outcome. For outcome=matched use selections=[{agent,expertise:[catalog expertise keys],confidence:low|medium|high,rationale}]; for no-match use rationale; for ambiguous use alternatives (same shape as selections) and rationale. Include exactly those fields. Select only available candidates from the catalog.") emptyParams)
          (Predict (mkSignature @InvestigationResult @InvestigationResult "Review the draft investigation. Keep its closed action, bounded summary and confidence. ReturnResult requires an empty routeJson; ProposeRoute requires a complete strict route proposal.") emptyParams)
      )
      jsonResultCodec
      (\input -> input <$ (bounded 4096 input.request >> bounded 2048 input.triageSummary >> bounded 65536 input.candidateCatalog))
      ( \result ->
          result
            <$ ( bounded 2048 result.summary >> confidenceValid result.confidence >> case result.action of
                   ReturnResult -> if Text.null result.routeJson then Right () else Left "return result must not carry a route"
                   ProposeRoute -> bounded 16384 result.routeJson
               )
      )

examplePrograms :: ProgramRegistry
examplePrograms = either (error . show) id (programRegistry [SomeProgram triageProgram, SomeProgram investigationProgram])

exampleCodecs :: ResultCodecRegistry
exampleCodecs = either (error . show) id (resultCodecRegistry [retainedCodec triageProgram, retainedCodec investigationProgram])

bounded :: Int -> Text -> Either Text ()
bounded maximum text
  | Text.null (Text.strip text) || Text.length text > maximum = Left "decision field is empty or too long"
  | otherwise = Right ()

confidenceValid :: Double -> Either Text ()
confidenceValid value
  | isNaN value || isInfinite value || value < 0 || value > 1 = Left "invalid confidence"
  | otherwise = Right ()

mustRegister :: (Show e) => Either e a -> a
mustRegister = either (error . show) id
