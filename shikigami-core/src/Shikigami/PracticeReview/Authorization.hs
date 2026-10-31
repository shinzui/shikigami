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

import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Bifunctor (first)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Hasql.Pool (Pool)
import Pgmq (MessageId)
import Shikigami.Agent.Name (mkAgentName)
import Shikigami.Agent.Principal (AgentIdentity)
import Shikigami.Agent.RunJob (RunRouteKind (AgentWorkflowRoute))
import Shikigami.PracticeReview
  ( OwnerPrincipal (..),
    PracticeReviewResolution (..),
    ResolutionId (..),
    ValidatedPracticeReviewResolution,
    validateResolution,
    validatedResolutionValue,
  )
import Shikigami.Prelude
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
  deriving stock (Eq, Show)

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
    resolution :: !PracticeReviewResolution,
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
  { authorize :: PracticeReviewResolution -> ResolutionSubmissionEvidence -> IO (Either ResolutionAuthorizationError AuthorizedResolutionReceipt)
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
  ValidatedPracticeReviewResolution ->
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
  Either ResolutionAuthorizationError (ValidatedPracticeReviewResolution, AuthorizedResolutionReceipt)
validateAuthorizedPracticeReviewResolution AuthorizedPracticeReviewResolution {schemaVersion, resolution, authorization}
  | schemaVersion /= authorizationEnvelopeSchemaVersion =
      Left (AuthorizationReceiptInvalid ("unsupported authorization envelope schema version: " <> Text.pack (show schemaVersion)))
  | otherwise = do
      validated <- firstContract (validateResolution resolution)
      validateReceipt validated authorization
      pure (validated, authorization)
  where
    firstContract = either (Left . ResolutionContractInvalid . Text.pack . show) Right

validateReceipt ::
  ValidatedPracticeReviewResolution ->
  AuthorizedResolutionReceipt ->
  Either ResolutionAuthorizationError ()
validateReceipt validated receipt@AuthorizedResolutionReceipt {authorizationId, verifiedSubject, sourceReference} = do
  let PracticeReviewResolution {resolver} = validatedResolutionValue validated
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

expectedAuthorizationId :: ValidatedPracticeReviewResolution -> AuthorizedResolutionReceipt -> Text
expectedAuthorizationId validated AuthorizedResolutionReceipt {authorityKind, verifiedSubject = OwnerPrincipal subject, sourceReference, authorizedAt} =
  let PracticeReviewResolution {resolutionId = ResolutionId resolutionId} = validatedResolutionValue validated
      preimage =
        Text.intercalate
          "|"
          [ "practice-review-resolution-authorization-v1",
            enumText authorityKind,
            subject,
            Text.strip sourceReference,
            Text.pack (iso8601Show authorizedAt),
            resolutionId
          ]
   in UUID.toText (UUID.V5.generateNamed UUID.V5.namespaceURL (nameBytes preimage))

enumText :: (ToJSON value) => value -> Text
enumText value = case Aeson.toJSON value of
  Aeson.String rendered -> rendered
  other -> error ("Shikigami.PracticeReview.Authorization: expected enum JSON string, got " <> show other)

enqueueAuthorizedPracticeReviewResolution ::
  Pool ->
  AgentIdentity ->
  Text ->
  ReviewResolutionAuthorizer ->
  PracticeReviewResolution ->
  ResolutionSubmissionEvidence ->
  IO (Either ResolutionAuthorizationError MessageId)
enqueueAuthorizedPracticeReviewResolution pool identity agent ReviewResolutionAuthorizer {authorize} resolution submission
  | agent /= "opentelemetry-practice-reviewer" =
      pure (Left (ResolutionAuthorizerRefused "authorized practice-review resolutions may target only the OpenTelemetry reviewer"))
  | otherwise =
      case validateResolution resolution of
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
                      PracticeReviewResolution {resolutionId = ResolutionId resolutionId} = validatedResolutionValue validated
                      key = agent <> ":resolution:" <> resolutionId
                  case (mkAgentName agent, Addressed.parseRequestKey key) of
                    (Left problem, _) -> pure (Left (ResolutionAuthorizerRefused problem))
                    (_, Left problem) -> pure (Left (ResolutionAuthorizerRefused problem))
                    (Right target, Right requestKey) ->
                      enqueueAddressedRunWithKey pool identity target AgentWorkflowRoute (Aeson.toJSON envelope) requestKey
                        <&> first (ResolutionEnqueueFailed . Text.pack . show)

authorizationEnvelopeSchemaVersion :: Int
authorizationEnvelopeSchemaVersion = 1

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
