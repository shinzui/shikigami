-- | Ingress authorization proof for explicit practice-review resolution.
module Shikigami.PracticeReview.Authorization
  ( ResolutionAuthorityKind (..),
    ResolutionSubmissionEvidence (..),
    AuthorizedResolutionReceipt (authorizationId, authorityKind, verifiedSubject, sourceReference, authorizedAt),
    AuthorizedPracticeReviewResolution (..),
    ReviewResolutionAuthorizer (..),
    ResolutionAuthorizationError (..),
    mkAuthorizedResolutionReceipt,
    validateAuthorizedPracticeReviewResolution,
    enqueueAuthorizedPracticeReviewResolution,
  )
where

import Data.Aeson ((.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Hasql.Pool (Pool)
import Pgmq (MessageId)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Agent.RunJob (RunRouteKind (AgentWorkflowRoute))
import Shikigami.Decision.Contract (versionedDigest)
import Shikigami.PracticeReview
  ( OwnerPrincipal,
    PracticeReviewResolutionRequest (..),
    ValidatedResolutionRequest,
    validateResolutionRequest,
    validatedResolutionRequestValue,
  )
import Shikigami.Prelude hiding ((.=))
import Shikigami.Trigger.Enqueue (enqueueAddressedRunWithKey)
import Shikigami.Trigger.RequestKey qualified as Addressed

data ResolutionAuthorityKind = Human | ApprovedArtifact
  deriving stock (Eq, Show, Generic)

instance ToJSON ResolutionAuthorityKind where
  toJSON = genericToJSON authorityEnumOptions

instance FromJSON ResolutionAuthorityKind where
  parseJSON = genericParseJSON authorityEnumOptions

-- | Opaque authentication material presented to the ingress authorizer. It is
-- deliberately not serializable and never crosses the run-job boundary.
newtype ResolutionSubmissionEvidence = ResolutionSubmissionEvidence {value :: Text}
  deriving stock (Eq)

instance Show ResolutionSubmissionEvidence where show _ = "<resolution-submission-evidence>"

data AuthorizedResolutionReceipt = AuthorizedResolutionReceipt
  { authorizationId :: !Text,
    authorityKind :: !ResolutionAuthorityKind,
    verifiedSubject :: !OwnerPrincipal,
    sourceReference :: !Text,
    authorizedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AuthorizedResolutionReceipt where
  toJSON = genericToJSON defaultOptions

instance FromJSON AuthorizedResolutionReceipt where
  parseJSON = Aeson.withObject "AuthorizedResolutionReceipt" \objectValue -> do
    rejectUnknownKeys "authorized resolution receipt" receiptKeys objectValue
    AuthorizedResolutionReceipt
      <$> objectValue .: "authorizationId"
      <*> objectValue .: "authorityKind"
      <*> objectValue .: "verifiedSubject"
      <*> objectValue .: "sourceReference"
      <*> objectValue .: "authorizedAt"

data AuthorizedPracticeReviewResolution = AuthorizedPracticeReviewResolution
  { schemaVersion :: !Int,
    resolution :: !PracticeReviewResolutionRequest,
    authorization :: !AuthorizedResolutionReceipt
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AuthorizedPracticeReviewResolution where
  toJSON = genericToJSON defaultOptions

instance FromJSON AuthorizedPracticeReviewResolution where
  parseJSON = Aeson.withObject "AuthorizedPracticeReviewResolution" \objectValue -> do
    rejectUnknownKeys "authorized resolution envelope" envelopeKeys objectValue
    AuthorizedPracticeReviewResolution
      <$> objectValue .: "schemaVersion"
      <*> objectValue .: "resolution"
      <*> objectValue .: "authorization"

newtype ReviewResolutionAuthorizer = ReviewResolutionAuthorizer
  { authorize :: PracticeReviewResolutionRequest -> ResolutionSubmissionEvidence -> IO (Either ResolutionAuthorizationError AuthorizedResolutionReceipt)
  }

data ResolutionAuthorizationError
  = ResolutionContractInvalid !Text
  | AuthorizationSubjectMismatch !OwnerPrincipal !OwnerPrincipal
  | AuthorizationSourceInvalid !Text
  | AuthorizationIdInvalid !Text !Text
  | AuthorizationReceiptInvalid !Text
  | ResolutionAuthorizerRefused !Text
  | ResolutionEnqueueFailed !Text
  deriving stock (Eq, Show, Generic)

instance ToJSON ResolutionAuthorizationError where toJSON = genericToJSON eventAesonOptions

instance FromJSON ResolutionAuthorizationError where parseJSON = genericParseJSON eventAesonOptions

mkAuthorizedResolutionReceipt ::
  ResolutionAuthorityKind ->
  OwnerPrincipal ->
  Text ->
  UTCTime ->
  ValidatedResolutionRequest ->
  Either ResolutionAuthorizationError AuthorizedResolutionReceipt
mkAuthorizedResolutionReceipt authorityKind verifiedSubject sourceReference authorizedAt validated = do
  validateSource sourceReference
  let receiptWithoutId =
        AuthorizedResolutionReceipt
          { authorizationId = "",
            authorityKind,
            verifiedSubject,
            sourceReference = Text.strip sourceReference,
            authorizedAt
          }
      authorizationId = expectedAuthorizationId validated receiptWithoutId
  pure receiptWithoutId {authorizationId}

validateAuthorizedPracticeReviewResolution ::
  AuthorizedPracticeReviewResolution ->
  Either ResolutionAuthorizationError (ValidatedResolutionRequest, AuthorizedResolutionReceipt)
validateAuthorizedPracticeReviewResolution AuthorizedPracticeReviewResolution {schemaVersion, resolution, authorization}
  | schemaVersion /= authorizationEnvelopeSchemaVersion =
      Left (AuthorizationReceiptInvalid ("unsupported authorization envelope schema version: " <> Text.pack (show schemaVersion)))
  | otherwise = do
      validated <- firstContract (validateResolutionRequest resolution)
      validateReceipt validated authorization
      pure (validated, authorization)
  where
    firstContract = either (Left . ResolutionContractInvalid . Text.pack . show) Right

validateReceipt ::
  ValidatedResolutionRequest ->
  AuthorizedResolutionReceipt ->
  Either ResolutionAuthorizationError ()
validateReceipt validated receipt@AuthorizedResolutionReceipt {authorizationId, verifiedSubject, sourceReference} = do
  let PracticeReviewResolutionRequest {resolver} = validatedResolutionRequestValue validated
  whenEither
    (verifiedSubject == resolver)
    (AuthorizationSubjectMismatch resolver verifiedSubject)
  validateSource sourceReference
  let expected = expectedAuthorizationId validated receipt
  whenEither
    (authorizationId == expected)
    (AuthorizationIdInvalid expected authorizationId)

validateSource :: Text -> Either ResolutionAuthorizationError ()
validateSource raw
  | "mori://" `Text.isPrefixOf` normalized = Right ()
  | "activity://" `Text.isPrefixOf` normalized = Right ()
  | otherwise = Left (AuthorizationSourceInvalid raw)
  where
    normalized = Text.strip raw

expectedAuthorizationId :: ValidatedResolutionRequest -> AuthorizedResolutionReceipt -> Text
expectedAuthorizationId validated AuthorizedResolutionReceipt {authorityKind, verifiedSubject, sourceReference, authorizedAt} =
  UUID.toText (UUID.V5.generateNamed UUID.V5.namespaceURL (nameBytes preimage))
  where
    preimage =
      versionedDigest
        "shikigami.practice-review-resolution-authorization/2"
        ( Aeson.object
            [ "request" .= validatedResolutionRequestValue validated,
              "authorityKind" .= authorityKind,
              "subject" .= verifiedSubject,
              "source" .= Text.strip sourceReference,
              "authorizedAt" .= authorizedAt
            ]
        )

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
        Right validated ->
          authorize resolution submission >>= \case
            Left refusal -> pure (Left refusal)
            Right receipt ->
              case validateReceipt validated receipt of
                Left refusal -> pure (Left refusal)
                Right () -> do
                  let envelope =
                        AuthorizedPracticeReviewResolution
                          { schemaVersion = authorizationEnvelopeSchemaVersion,
                            resolution,
                            authorization = receipt
                          }
                      PracticeReviewResolutionRequest {reviewId, idempotencyKey} = validatedResolutionRequestValue validated
                      key = versionedDigest "shikigami.practice-review-resolution-enqueue/2" (Aeson.object ["reviewId" .= reviewId, "key" .= idempotencyKey])
                  case (mkAgentName agent, Addressed.parseRequestKey key) of
                    (Left problem, _) -> pure (Left (ResolutionAuthorizerRefused problem))
                    (_, Left problem) -> pure (Left (ResolutionAuthorizerRefused problem))
                    (Right target, Right requestKey) ->
                      enqueueAddressedRunWithKey pool identity target AgentWorkflowRoute (Aeson.toJSON envelope) requestKey
                        <&> first (ResolutionEnqueueFailed . Text.pack . show)

authorizationEnvelopeSchemaVersion :: Int
authorizationEnvelopeSchemaVersion = 2

authorityEnumOptions :: Options
authorityEnumOptions =
  defaultOptions
    { constructorTagModifier = camelTo2 '-',
      allNullaryToStringTag = True
    }

receiptKeys :: Set.Set Key.Key
receiptKeys = Set.fromList ["authorizationId", "authorityKind", "verifiedSubject", "sourceReference", "authorizedAt"]

envelopeKeys :: Set.Set Key.Key
envelopeKeys = Set.fromList ["schemaVersion", "resolution", "authorization"]

rejectUnknownKeys :: String -> Set.Set Key.Key -> Aeson.Object -> Parser ()
rejectUnknownKeys label allowed objectValue =
  case Set.toAscList (Set.fromList (KeyMap.keys objectValue) `Set.difference` allowed) of
    [] -> pure ()
    extras -> fail (label <> " contains unknown fields: " <> show (Key.toText <$> extras))

whenEither :: Bool -> error -> Either error ()
whenEither True _ = Right ()
whenEither False err = Left err
